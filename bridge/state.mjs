import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, rename, chmod } from 'node:fs/promises';
import { basename, join } from 'node:path';

export const defaults = {
  organization: '', project: '', repository: '', myEmail: '', colleagueEmail: '', team: '',
  authentication: 'interactive', tokenEnvironmentVariable: 'ADO_MCP_AUTH_TOKEN',
  dueDateField: '', notifications: true, showNotch: true, importHistory: true,
};
export const blankState = () => ({
  sessions: [], activity: [], pullRequests: [], pipelines: [], workItems: [],
  connection: 'disconnected', lastSync: null, baselines: {}, errors: [], hookStatus: '',
});
export const stableID = (...parts) => createHash('sha256').update(parts.join('|')).digest('hex').slice(0, 32);
export const now = () => new Date().toISOString();
export function text(value, limit = 200000) { return typeof value === 'string' ? value.slice(0, limit) : ''; }

export async function atomicJSON(path, data) {
  const temporary = path + '.' + process.pid + '.tmp';
  await writeFile(temporary, JSON.stringify(data), { mode: 0o600 });
  await rename(temporary, path);
  await chmod(path, 0o600);
}

export class Store {
  constructor(directory, onChange = () => {}, onNotice = () => {}) {
    this.directory = directory; this.onChange = onChange; this.onNotice = onNotice;
    this.state = blankState(); this.settings = { ...defaults }; this.writeQueue = Promise.resolve();
    this.recentEvents = new Set();
  }
  async load() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    await chmod(this.directory, 0o700);
    for (const [name, target] of [['settings', 'settings'], ['state', 'state']]) {
      try { this[target] = { ...this[target], ...JSON.parse(await readFile(join(this.directory, name + '.json'), 'utf8')) }; }
      catch (e) {
        if (e.code !== 'ENOENT') {
          const backup = name + '.unreadable.' + Date.now() + '.json';
          await rename(join(this.directory, name + '.json'), join(this.directory, backup));
          this.state.errors.push('Could not read ' + name + '; preserved as ' + backup + '.');
        }
      }
    }
    this.state.connection = 'disconnected';
    this.state.sessions = this.state.sessions.map(s => ({ ...s, state: ['working', 'thinking', 'waiting'].includes(s.state) ? 'unknown' : s.state }));
  }
  snapshot() { return { ...this.state, settings: this.settings }; }
  publish() {
    this.state.sessions.sort((a,b) => b.updatedAt.localeCompare(a.updatedAt));
    this.state.sessions = this.state.sessions.slice(0, 200);
    this.state.activity = this.state.activity.slice(0, 500);
    this.onChange(this.snapshot());
    clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => this.flush().catch(() => {}), 300);
  }
  async flush() {
    clearTimeout(this.saveTimer);
    const snapshot = JSON.parse(JSON.stringify(this.state));
    this.writeQueue = this.writeQueue.catch(() => {}).then(() => atomicJSON(join(this.directory, 'state.json'), snapshot));
    return this.writeQueue;
  }
  async saveSettings(settings) {
    this.settings = Object.fromEntries(Object.entries({ ...this.settings, ...settings }).filter(([key]) => key in defaults));
    await atomicJSON(join(this.directory, 'settings.json'), this.settings);
    this.publish();
  }
  notice(key, title, body, { url = '', sessionID = '', silent = false } = {}) {
    if (this.state.activity.some(x => x.id === key)) return;
    const entry = { id: key, title, body: text(body, 2000), date: now(), read: false, url, sessionID };
    this.state.activity.unshift(entry);
    if (!silent && this.settings.notifications) this.onNotice(entry);
  }
  ingest(payload, { historical = false } = {}) {
    if (!payload || typeof payload !== 'object') return;
    const agent = payload.agent === 'codex' || payload.coucou_agent === 'codex' ? 'codex' : 'claude';
    const externalID = text(payload.session_id || payload.sessionId, 200);
    if (!externalID) return;
    const name = payload.hook_event_name;
    const eventID = text(payload.event_id, 200);
    if (eventID && this.recentEvents.has(eventID)) return;
    if (eventID) this.recentEvents.add(eventID);
    if (this.recentEvents.size > 5000) this.recentEvents.delete(this.recentEvents.values().next().value);
    const id = agent + ':' + externalID;
    let session = this.state.sessions.find(s => s.id === id);
    const timestamp = typeof payload.timestamp === 'string' && Number.isFinite(Date.parse(payload.timestamp)) ? new Date(payload.timestamp).toISOString() : now();
    if (!session) {
      session = { id, agent, externalID, title: '', project: 'Session', cwd: '', branch: '', state: 'idle',
        updatedAt: timestamp, answers: [], steps: [], transcriptPath: '', source: historical ? 'history' : 'hooks' };
      this.state.sessions.push(session);
    }
    if (historical && session.source === 'hooks' && timestamp <= session.updatedAt) {
      // History can fill answers, but must not revert a newer live state.
      if (name !== 'Stop') return;
    }
    const isNewer = timestamp >= session.updatedAt;
    const cwd = text(payload.cwd, 4000);
    if (cwd) { session.cwd = cwd; session.project = basename(cwd) || cwd; }
    if (payload.branch) session.branch = text(payload.branch, 300);
    if (payload.transcript_path) session.transcriptPath = text(payload.transcript_path, 4000);
    if (!historical) session.source = 'hooks';
    const step = (label) => {
      session.steps.push({ id: eventID || randomUUID(), text: text(label, 1000), date: timestamp });
      session.steps = session.steps.slice(-60);
    };
    const setState = value => { if (isNewer) session.state = value; };
    switch (name) {
      case 'SessionStart': setState('idle'); break;
      case 'UserPromptSubmit':
        setState('thinking');
        if (payload.prompt) { session.title = text(payload.prompt, 200); step(payload.prompt); }
        break;
      case 'PreToolUse': setState('working'); step(payload.tool_name || 'Working'); break;
      case 'PostToolUse': setState('working'); break;
      case 'PostToolUseFailure': setState('working'); step('Tool failed: ' + (payload.tool_name || 'tool')); break;
      case 'PermissionRequest':
        setState('waiting'); step('Waiting for permission in ' + (agent === 'codex' ? 'Codex' : 'Claude Code'));
        if (!historical) this.notice(stableID(id, 'permission', payload.tool_use_id || eventID), 'Permission needed', session.title || session.project, { sessionID: id });
        break;
      case 'Notification': setState('waiting'); step(payload.message || 'Input needed'); break;
      case 'Stop': {
        setState('finished');
        const answer = text(payload.last_assistant_message || payload.message);
        const answerID = stableID(id, payload.turn_id || '', answer);
        if (answer && !session.answers.some(a => a.id === answerID || a.text === answer && a.date === timestamp)) {
          session.answers.push({ id: answerID, text: answer, date: timestamp });
          session.answers = session.answers.slice(-50);
        }
        if (!historical) this.notice(answerID, 'Session finished', answer || session.title || session.project, { sessionID: id });
        break;
      }
      case 'StopFailure': setState('error'); if (!historical) this.notice(stableID(id, eventID), 'Session failed', session.title || session.project, { sessionID: id }); break;
      case 'Interrupt': setState('idle'); break;
      case 'SessionEnd': setState('ended'); break;
      case 'SubagentStart': step('Subagent started'); break;
      case 'SubagentStop': step('Subagent finished'); break;
      case 'WorktreeReady': case 'BranchPushed':
        this.notice(stableID(id, name, payload.commit || eventID), name === 'WorktreeReady' ? 'Worktree ready' : 'Branch pushed', [session.project, session.branch].filter(Boolean).join(' · '), { sessionID: id });
        break;
      default: return;
    }
    if (isNewer) session.updatedAt = timestamp;
    if (!historical) this.publish();
  }
  updateADO(kind, items) {
    const prior = this.state[kind];
    const hadBaseline = Boolean(this.state.baselines[kind]);
    if (hadBaseline) {
      for (const item of items) {
        const old = prior.find(x => x.id === item.id);
        if (kind === 'pipelines' && old && old.status !== item.status && ['succeeded','failed','partiallySucceeded','canceled'].includes(item.status)) {
          this.notice(stableID('build', item.id, item.status), 'Pipeline ' + item.status, item.name + ' · ' + item.branch, { url: item.url });
        }
        if (kind === 'pullRequests' && item.reviewRequested && !old?.reviewRequested) {
          this.notice(stableID('review', item.id), 'Added as reviewer', item.title, { url: item.url });
        }
        if (kind === 'workItems' && !old && item.buckets.includes('today')) {
          this.notice(stableID('workitem', item.id), 'New work item today', item.title, { url: item.url });
        }
      }
    }
    this.state[kind] = items;
    this.state.baselines[kind] = true;
  }
}
