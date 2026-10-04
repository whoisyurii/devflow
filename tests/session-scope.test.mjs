import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rm, symlink } from 'node:fs/promises';
import { join } from 'node:path';
import { Store } from '../bridge/state.mjs';
import { SessionMonitor, transcriptName } from '../bridge/session-scope.mjs';
import { History } from '../bridge/history.mjs';
const git = (cwd, ...args) => execFileSync('/usr/bin/git', ['-C',cwd,...args], {stdio:'pipe'}).toString().trim();

async function setup(t) {
  const root = await mkdtemp('/private/tmp/df-scope-');
  const repo = join(root, 'main'); await mkdir(join(repo,'React.BFF','ClientApp'),{recursive:true});
  git(repo,'init','-b','main');
  await writeFile(join(repo,'React.BFF','ClientApp','fixture.txt'),'fixture');
  git(repo,'add','.'); git(repo,'-c','user.name=Fixture','-c','user.email=fixture@example.com','commit','-m','fixture');
  const tree = join(root,'separate-tree'); git(repo,'worktree','add','-b','feature/parallel',tree);
  const other = join(root,'other'); await mkdir(join(other,'React.BFF','ClientApp'),{recursive:true}); git(other,'init');
  const notices = []; const store = new Store(join(root,'data'),()=>{},n=>notices.push(n)); await store.load();
  store.settings.sessionRepositoryPath = repo;
  const monitor = new SessionMonitor(store);
  t.after(async()=>{await store.flush(); await rm(root,{recursive:true,force:true});});
  return {root,repo,tree,other,store,monitor,notices};
}

test('scope admits React.BFF and root sessions across linked trees, rejects sibling projects and other repos', async t => {
  const {repo,tree,other,monitor,root,store} = await setup(t);
  assert.ok(await monitor.scope.match(join(repo,'React.BFF','ClientApp')));
  assert.ok(await monitor.scope.match(repo));
  assert.equal((await monitor.scope.match(join(tree,'React.BFF'))).branch,'feature/parallel');
  assert.equal(await monitor.scope.match(join(other,'React.BFF','ClientApp')),null);
  await mkdir(join(repo,'React.BFF-other')); assert.equal(await monitor.scope.match(join(repo,'React.BFF-other')),null);
  await mkdir(join(repo,'landing')); assert.equal(await monitor.scope.match(join(repo,'landing')),null);
  await symlink(other,join(repo,'React.BFF','external'));
  assert.equal(await monitor.scope.match(join(repo,'React.BFF','external')),null);
  store.settings.includeRepositoryRoot=false; assert.equal(await monitor.scope.match(repo),null);
  store.settings.sessionSubdirectory='../other'; assert.equal(await monitor.scope.match(repo),null);
  assert.equal(await monitor.scope.match(root),null);
});

test('parallel sessions keep worktree, branch and notification context separate for both agents', async t => {
  const {repo,tree,store,monitor,notices} = await setup(t);
  for (const [agent,cwd] of [['codex',repo],['claude',tree]]) {
    await monitor.ingest({agent,cwd,session_id:'same-id',hook_event_name:'UserPromptSubmit',prompt:agent+' task'});
    await monitor.ingest({agent,cwd,session_id:'same-id',hook_event_name:'PermissionRequest',tool_name:'Bash',tool_use_id:'tool',pending_summary:'Run the tests?'});
  }
  assert.equal(store.state.sessions.length,2); assert.equal(notices.length,2);
  assert.equal(notices[0].branch,'main'); assert.equal(notices[1].branch,'feature/parallel');
  assert.equal(notices[1].worktree,'separate-tree'); assert.equal(notices[1].sessionTitle,'claude task');
  assert.equal(notices[1].pending,'Run the tests?');
  assert.notEqual(notices[0].sessionID,notices[1].sessionID);
  git(tree,'switch','-c','feature/changed');
  await monitor.ingest({agent:'claude',cwd:tree,session_id:'same-id',hook_event_name:'Stop',last_assistant_message:'Done'});
  assert.equal(notices.at(-1).branch,'feature/changed');
  assert.equal(store.state.sessions.find(s=>s.agent==='codex').state,'waiting');
});

test('provider choice filters UI and alerts without destroying the other provider history', async t => {
  const {repo,store,monitor,notices} = await setup(t);
  store.settings.agentProvider='codex';
  for (const agent of ['codex','claude']) await monitor.ingest({agent,cwd:repo,session_id:agent,hook_event_name:'Stop',last_assistant_message:'Done'});
  assert.equal(store.state.sessions.length,2); assert.equal(store.snapshot().sessions.length,1); assert.equal(notices.length,1);
  store.settings.agentProvider='claude'; assert.equal(store.snapshot().sessions[0].agent,'claude');
  assert.equal(store.snapshot().activity.length,1);
});

test('old unrelated sessions and inbox entries are removed while Azure history remains', async t => {
  const {repo,other,store,monitor} = await setup(t);
  store.ingest({agent:'codex',cwd:other,session_id:'outside',hook_event_name:'Stop',last_assistant_message:'Old'});
  await monitor.ingest({agent:'codex',cwd:repo,session_id:'inside',hook_event_name:'Stop',last_assistant_message:'Done'});
  store.notice('azure','Pipeline succeeded','CI');
  await monitor.reconcile();
  assert.equal(store.state.sessions.length,1);
  assert.deepEqual(store.state.activity.map(n=>n.title).sort(),['Pipeline succeeded','Session finished']);
  assert.equal(await monitor.ingest({agent:'claude',cwd:other,session_id:'new-outside',hook_event_name:'Notification',message:'No'}),false);
});

test('missing worktrees retain previously verified session context on restart', async t => {
  const {repo,tree,store,monitor} = await setup(t);
  await monitor.ingest({agent:'claude',cwd:tree,session_id:'removed',hook_event_name:'Stop',last_assistant_message:'Done'});
  git(repo,'worktree','remove',tree);
  await monitor.reconcile();
  assert.equal(store.state.sessions.length,1); assert.equal(store.state.sessions[0].worktree,'separate-tree');
});

test('detached worktrees keep their own identity and commit label', async t => {
  const {tree,monitor} = await setup(t);
  git(tree,'checkout','--detach');
  const info=await monitor.scope.match(tree);
  assert.equal(info.branch,'detached '+git(tree,'rev-parse','HEAD').slice(0,7));
  assert.equal(info.worktree,'separate-tree');
});

test('history scopes before import, accepts a final line without newline, and stays silent', async t => {
  const {root,repo,tree,other,monitor,store,notices}=await setup(t);
  const home=join(root,'home'), directory=join(home,'.codex','sessions');
  await mkdir(directory,{recursive:true});
  for (const [id,cwd] of [['outside',other],['inside',tree]]) {
    const rows=[{type:'session_meta',timestamp:'2026-10-03T12:00:00Z',payload:{id,cwd}},
      {type:'event_msg',timestamp:'2026-10-03T12:01:00Z',payload:{type:'user_message',message:'Scoped history'}},
      {type:'event_msg',timestamp:'2026-10-03T12:02:00Z',payload:{type:'task_complete',last_agent_message:'Done'}}];
    await writeFile(join(directory,id+'.jsonl'),rows.map(JSON.stringify).join('\n'));
  }
  const history=new History(store,home,monitor); await history.importRecent();
  assert.equal(store.state.sessions.length,1); assert.equal(store.state.sessions[0].externalID,'inside');
  assert.equal(store.state.sessions[0].branch,'feature/parallel'); assert.equal(store.state.sessions[0].answers[0].text,'Done');
  assert.equal(notices.length,0); assert.equal(store.state.activity.length,0);
});

test('live previews can use the latest explicit transcript name without reading arbitrary files', async t => {
  const {root}=await setup(t);
  const directory=join(root,'.claude/projects'); await mkdir(directory,{recursive:true});
  const path=join(directory,'session.jsonl');
  await writeFile(path,[{type:'custom-title',customTitle:'Old name'}, {type:'custom-title',customTitle:'Named worktree task'}].map(JSON.stringify).join('\n'));
  assert.equal(await transcriptName(path,'claude',root),'Named worktree task');
  assert.equal(await transcriptName(path,'codex',root),'');
  const outside=join(root,'outside.jsonl'); await writeFile(outside,JSON.stringify({type:'custom-title',customTitle:'Outside'}));
  await symlink(outside,join(directory,'escape.jsonl'));
  assert.equal(await transcriptName(join(directory,'escape.jsonl'),'claude',root),'');
});
