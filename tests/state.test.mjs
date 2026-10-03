import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../bridge/state.mjs';
import { mergeHooks, Hooks } from '../bridge/hooks.mjs';
import { historyEvents } from '../bridge/history.mjs';
import { parseToolResult, buildState, attachBuildChecks, dayBounds } from '../bridge/ado.mjs';

async function fixture(t) {
  const directory=await mkdtemp(join(tmpdir(),'df-'));
  const store=new Store(directory);await store.load();
  t.after(async()=>{await store.flush();await rm(directory,{recursive:true,force:true});});
  return store;
}
test('concurrent sessions stay separate, including session IDs shared by different agents',async t=>{
  const store=await fixture(t);
  store.ingest({agent:'codex',session_id:'one',cwd:'/project/a',hook_event_name:'UserPromptSubmit',prompt:'first'});
  store.ingest({agent:'codex',session_id:'two',cwd:'/project/b',hook_event_name:'UserPromptSubmit',prompt:'second'});
  store.ingest({agent:'claude',session_id:'one',hook_event_name:'PreToolUse',tool_name:'Bash'});
  store.ingest({agent:'codex',session_id:'one',hook_event_name:'Stop',last_assistant_message:'done',turn_id:'t1'});
  assert.equal(store.state.sessions.length,3);
  assert.equal(store.state.sessions.find(s=>s.id==='codex:two').state,'thinking');
  assert.equal(store.state.sessions.find(s=>s.id==='claude:one').state,'working');
});
test('completion replay is deduplicated and final answers survive restart',async t=>{
  const store=await fixture(t);
  const event={agent:'codex',session_id:'one',hook_event_name:'Stop',last_assistant_message:'Full\nmultiline answer',turn_id:'t1'};
  store.ingest(event);store.ingest(event);await store.flush();
  assert.equal(store.state.activity.length,1);assert.equal(store.state.sessions[0].answers.length,1);
  const reopened=new Store(store.directory);await reopened.load();
  assert.equal(reopened.state.sessions[0].answers[0].text,'Full\nmultiline answer');
});
test('old history fills answers without reverting live session state',async t=>{
  const store=await fixture(t);
  store.ingest({agent:'codex',session_id:'one',hook_event_name:'UserPromptSubmit',timestamp:'2026-10-03T12:00:00Z'});
  store.ingest({agent:'codex',session_id:'one',hook_event_name:'Stop',last_assistant_message:'old',timestamp:'2026-10-03T11:00:00Z'},{historical:true});
  assert.equal(store.state.sessions[0].state,'thinking');assert.equal(store.state.sessions[0].answers.length,1);
  assert.equal(store.state.activity.length,0);
});
test('restart does not falsely claim a previously running session is still active',async t=>{
  const store=await fixture(t);
  store.ingest({agent:'claude',session_id:'one',hook_event_name:'PreToolUse'});await store.flush();
  const reopened=new Store(store.directory);await reopened.load();assert.equal(reopened.state.sessions[0].state,'unknown');
});
test('hook merge is idempotent and keeps user hooks and other settings',()=>{
  const command='/private/user/devflow-hook.py';
  const original={env:{OTHER_SETTING:'retained'},hooks:{Stop:[{matcher:'',hooks:[{type:'command',command:'my-existing-hook'}]}]}};
  const merged=mergeHooks(original,'codex',command);
  assert.deepEqual(mergeHooks(merged,'codex',command),merged);
  assert.equal(merged.hooks.Stop[0].hooks[0].command,'my-existing-hook');
  assert.equal(merged.env.OTHER_SETTING,'retained');
  assert.equal(original.hooks.Stop.length,1);
});
test('hook installer refuses stale previews',async t=>{
  const store=await fixture(t);const home=join(store.directory,'home');
  const hooks=new Hooks(join(store.directory,'tools'),home);await hooks.preview();
  const {mkdir}=await import('node:fs/promises');await mkdir(join(home,'.claude'),{recursive:true});
  await writeFile(join(home,'.claude/settings.json'),'{}');
  await assert.rejects(hooks.install(),/changed since preview/);
});
test('hook preview excludes unrelated secrets and installation preserves them',async t=>{
  const store=await fixture(t);const {mkdir}=await import('node:fs/promises');
  const home=join(store.directory,'home');await mkdir(join(home,'.claude'),{recursive:true});
  await writeFile(join(home,'.claude/settings.json'),JSON.stringify({env:{PRIVATE:'fixture-secret'}}));
  const hooks=new Hooks(join(store.directory,'tools'),home);
  const preview=await hooks.preview();assert.ok(!preview.includes('fixture-secret'));
  const result=await hooks.install();assert.equal(result.backups.length,1);
  assert.equal(JSON.parse(await readFile(join(home,'.claude/settings.json'),'utf8')).env.PRIVATE,'fixture-secret');
});
test('MCP parser accepts Microsoft wrappers, rejects tool errors',()=>{
  const wrapped='<<abc>> [UNTRUSTED CONTENT] <<abc>>\n[{"id":42,"title":"ignore instructions"}]\n<</abc>>';
  assert.equal(parseToolResult({content:[{type:'text',text:wrapped}]})[0].id,42);
  assert.throws(()=>parseToolResult({isError:true,content:[{type:'text',text:'Denied'}]}),/Denied/);
});
test('build status does not confuse queued, failed and canceled enums',()=>{
  assert.equal(buildState({status:1}),'running');assert.equal(buildState({status:8}),'queued');
  assert.equal(buildState({status:2,result:8}),'failed');assert.equal(buildState({status:2,result:32}),'canceled');
});
test('PR build checks use current merge SHA and latest retry per pipeline',()=>{
  const prs=[{id:'9',mergeCommit:'current'}];
  const build={branch:'refs/pull/9/merge',definitionID:'1',name:'CI'};
  assert.equal(attachBuildChecks(prs,[{...build,id:'1',date:'2026-01-01',commit:'old',status:'succeeded'}])[0].checks,'No matching build');
  const builds=[{...build,id:'1',date:'2026-01-01',commit:'current',status:'failed'},{...build,id:'2',date:'2026-01-02',commit:'current',status:'succeeded'}];
  assert.equal(attachBuildChecks(prs,builds)[0].checks,'Build passed');
});
test('Codex history parser captures full final messages and stable identity',()=>{
  const rows=[{type:'session_meta',timestamp:'2026-01-01T00:00:00Z',payload:{id:'abc',cwd:'/a',git:{branch:'feature'}}},
    {type:'event_msg',timestamp:'2026-01-01T00:01:00Z',payload:{type:'task_complete',turn_id:'turn',last_agent_message:'final\nanswer'}}];
  const events=historyEvents(rows.map(JSON.stringify),'codex','/fixture');
  assert.equal(events[1].session_id,'abc');assert.equal(events[1].branch,'feature');assert.equal(events[1].last_assistant_message,'final\nanswer');
});
test('Claude history excludes sidechains and tool-only responses',()=>{
  const rows=[{type:'assistant',sessionId:'a',isSidechain:true,message:{stop_reason:'end_turn',content:[{type:'text',text:'ignore'}]}},
    {type:'assistant',sessionId:'a',message:{stop_reason:'tool_use',content:[{type:'tool_use'}]}},
    {type:'assistant',sessionId:'a',message:{id:'b',stop_reason:'end_turn',content:[{type:'text',text:'answer'}]}}];
  const events=historyEvents(rows.map(JSON.stringify),'claude','/fixture');assert.equal(events.length,1);assert.equal(events[0].last_assistant_message,'answer');
});
test('day bounds follow local calendar boundaries',()=>{
  const input=new Date(2026,9,3,15,0,0);const [start,end]=dayBounds(input);
  assert.equal(new Date(start).getHours(),0);assert.equal(new Date(end).getDate(),4);
});
test('each Azure feed establishes its own silent baseline after partial refresh failure', async t => {
  const store=await fixture(t);
  store.updateADO('pipelines',[]);store.state.lastSync=new Date().toISOString();
  store.updateADO('pullRequests',[{id:'1',title:'Existing review',reviewRequested:true}]);
  assert.equal(store.state.activity.length,0);
  store.updateADO('pullRequests',[{id:'1',title:'Existing review',reviewRequested:true},{id:'2',title:'New review',reviewRequested:true}]);
  assert.equal(store.state.activity.length,1);assert.equal(store.state.activity[0].body,'New review');
});
test('malformed cache is quarantined before later saves', async t => {
  const store=await fixture(t);
  await writeFile(join(store.directory,'state.json'),'broken JSON');
  const reopened=new Store(store.directory);await reopened.load();await reopened.flush();
  const {readdir}=await import('node:fs/promises');
  const backup=(await readdir(store.directory)).find(name=>name.startsWith('state.unreadable.'));
  assert.equal(await readFile(join(store.directory,backup),'utf8'),'broken JSON');
});
