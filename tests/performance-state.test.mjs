import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, appendFile, utimes, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { Store } from '../bridge/state.mjs';
import { History } from '../bridge/history.mjs';

async function fixture(t) {
  const directory = await mkdtemp('/private/tmp/df-publish-');
  const snapshots = [], notices = [];
  const store = new Store(directory, state => snapshots.push(structuredClone(state)), entry => notices.push(entry));
  await store.load();
  t.mock.timers.enable({ apis: ['setTimeout'] });
  t.after(async () => { await store.flush(); await rm(directory, { recursive: true, force: true }); });
  const emit = (hook_event_name, extra = {}) => store.ingest({
    agent: 'codex', session_id: 'fixture', cwd: '/fixture', hook_event_name, ...extra,
  });
  return { directory, store, snapshots, notices, emit };
}

test('hook bursts batch snapshots without delaying notices or losing final answers', async t => {
  const { store, snapshots, notices, emit } = await fixture(t);
  for (let i = 0; i < 12; i++) emit('PreToolUse', { tool_name: 'Tool ' + i, event_id: 'tool-' + i });
  emit('PermissionRequest', { tool_name: 'Bash', tool_use_id: 'approval' });
  const answer = 'Complete multiline answer\n'.repeat(200);
  emit('Stop', { last_assistant_message: answer, turn_id: 'turn' });
  assert.equal(notices.length, 2, 'Notices must be delivered immediately');
  assert.equal(snapshots.length, 0);
  assert.equal(store.snapshot().sessions[0].answers[0].text, answer, 'Explicit snapshots see current state immediately');
  t.mock.timers.tick(74); assert.equal(snapshots.length, 0);
  t.mock.timers.tick(1); assert.equal(snapshots.length, 1);
  assert.equal(snapshots[0].sessions[0].state, 'finished');
  assert.equal(snapshots[0].sessions[0].steps.length, 13);
  assert.equal(snapshots[0].sessions[0].answers[0].text, answer);
  assert.deepEqual(snapshots[0].activity.map(a => a.id), store.state.activity.map(a => a.id));
});

test('continuous hook activity cannot postpone the fixed publication deadline', async t => {
  const { snapshots, emit } = await fixture(t);
  emit('PreToolUse', { tool_name: 'first' });
  t.mock.timers.tick(50); emit('PostToolUse');
  t.mock.timers.tick(25); assert.equal(snapshots.length, 1);
  emit('PreToolUse', { tool_name: 'next' });
  t.mock.timers.tick(50); emit('PostToolUse');
  t.mock.timers.tick(25); assert.equal(snapshots.length, 2);
});

test('flush publishes a pending state and captures immutable JSON before the write queue', async t => {
  const { directory, store, snapshots, emit } = await fixture(t);
  emit('Stop', { last_assistant_message: 'Before queued write', turn_id: 'one' });
  const writing = store.flush();
  store.state.sessions[0].answers[0].text = 'Changed after capture';
  await writing;
  assert.equal(JSON.parse(await readFile(join(directory, 'state.json'), 'utf8')).sessions[0].answers[0].text, 'Before queued write');
  assert.equal(snapshots.length, 1);
  t.mock.timers.tick(75); assert.equal(snapshots.length, 1, 'Flush cancels the pending publication timer');
  await store.flush();
  const reopened = new Store(directory); await reopened.load();
  assert.equal(reopened.state.sessions[0].answers[0].text, 'Changed after capture');
});

test('unchanged history and transcript noise do not broadcast or save another snapshot', async t => {
  const { directory, store, snapshots, notices } = await fixture(t);
  const home = join(directory, 'home'), sessions = join(home, '.codex', 'sessions');
  await mkdir(sessions, { recursive: true });
  const path = join(sessions, 'fixture.jsonl');
  const rows = [
    { type: 'session_meta', timestamp: '2026-10-04T01:00:00Z', payload: { id: 'fixture', cwd: '/fixture' } },
    { type: 'event_msg', timestamp: '2026-10-04T01:01:00Z', payload: { type: 'task_complete', turn_id: 'one', last_agent_message: 'First answer' } },
  ];
  await writeFile(path, rows.map(JSON.stringify).join('\n') + '\n');
  const history = new History(store, home);
  await history.importRecent(); t.mock.timers.tick(75);
  assert.equal(snapshots.length, 1); await store.flush();
  await history.importRecent();
  assert.equal(store.publishTimer, null); t.mock.timers.tick(75); assert.equal(snapshots.length, 1);
  await appendFile(path, JSON.stringify({ type: 'event_msg', payload: { type: 'token_count' } }) + '\n');
  await utimes(path, new Date(), new Date(Date.now() + 1000));
  await history.importRecent();
  assert.equal(store.publishTimer, null, 'Replayed event IDs and non-session log records do not publish');
  await appendFile(path, JSON.stringify({ type: 'event_msg', timestamp: '2026-10-04T01:02:00Z', payload: {
    type: 'task_complete', turn_id: 'two', last_agent_message: 'Second full answer\nwith another line',
  } }) + '\n');
  await utimes(path, new Date(), new Date(Date.now() + 2000));
  await history.importRecent(); t.mock.timers.tick(75);
  assert.equal(snapshots.length, 2);
  assert.deepEqual(store.state.sessions[0].answers.map(a => a.text), ['First answer', 'Second full answer\nwith another line']);
  assert.equal(notices.length, 0, 'History remains silent');
});

test('history still publishes stale-status transitions when no transcript changed', async t => {
  const { directory, store, snapshots } = await fixture(t);
  store.ingest({ agent: 'claude', session_id: 'stale', hook_event_name: 'PreToolUse',
    timestamp: new Date(Date.now() - 180001).toISOString() }, { historical: true });
  const history = new History(store, join(directory, 'empty-home'));
  await history.importRecent(); t.mock.timers.tick(75);
  assert.equal(snapshots.length, 1); assert.equal(snapshots[0].sessions[0].state, 'unknown');
  await history.importRecent(); t.mock.timers.tick(75); assert.equal(snapshots.length, 1);
});
