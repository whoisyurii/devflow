import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../bridge/state.mjs';

function fixture(t) {
  const notices = []; const store = new Store('/unused',()=>{},n=>notices.push(n));
  t.after(()=>{clearTimeout(store.saveTimer);clearTimeout(store.publishTimer);});
  const emit = (name,extra={}) => store.ingest({agent:'claude',session_id:'one',cwd:'/repo/React.BFF',branch:'feature',worktree:'tree',hook_event_name:name,...extra});
  return {store,notices,emit};
}
test('Claude permission notification and permission hook produce one contextual notice', t => {
  const {emit,notices}=fixture(t);
  emit('UserPromptSubmit',{prompt:'Fix upload'});
  emit('PermissionRequest',{tool_use_id:'tool',tool_name:'Bash',pending_summary:'Run checks'});
  emit('Notification',{notification_type:'permission_prompt',message:'Permission needed'});
  assert.equal(notices.length,1); assert.equal(notices[0].sessionTitle,'Fix upload');
  assert.equal(notices[0].pending,'Run checks');
});
test('questions, completion and failures notify; non-actionable Claude notices do not', t => {
  const {emit,notices,store}=fixture(t);
  emit('UserPromptSubmit',{prompt:'Fix upload'});
  emit('PreToolUse',{tool_name:'AskUserQuestion',pending_summary:'Which option?',tool_use_id:'question'});
  assert.equal(store.state.sessions[0].state,'waiting'); assert.equal(notices.at(-1).body,'Which option?');
  emit('PostToolUse'); assert.equal(store.state.sessions[0].pending,'');
  emit('Stop',{last_assistant_message:'All done'});
  emit('Stop',{last_assistant_message:'All done'});
  emit('Notification',{notification_type:'idle_prompt',message:'Idle'});
  emit('Notification',{notification_type:'auth_success',message:'Signed in'});
  assert.equal(notices.length,2); assert.equal(store.state.sessions[0].state,'finished');
  emit('StopFailure',{error:'rate_limit'}); assert.equal(notices.at(-1).title,'Session failed');
});
test('idle/input notifications alert and disabled notifications remain silent', t => {
  const {emit,notices,store}=fixture(t);
  emit('Notification',{notification_type:'elicitation_dialog',message:'Pick an account'});
  assert.equal(notices[0].pending,'Pick an account');
  store.settings.notifications=false;
  emit('Stop',{last_assistant_message:'Done'}); assert.equal(notices.length,1); assert.equal(store.state.activity.length,2);
});
test('historical answers cannot clear a newer pending prompt or generate a live alert', t => {
  const {store,emit,notices}=fixture(t);
  emit('UserPromptSubmit',{prompt:'Session name',timestamp:'2026-10-04T12:00:00Z'});
  emit('PermissionRequest',{tool_name:'Bash',timestamp:'2026-10-04T12:01:00Z'});
  store.ingest({agent:'claude',session_id:'one',hook_event_name:'Stop',last_assistant_message:'Old',timestamp:'2026-10-03T12:00:00Z'},{historical:true});
  assert.equal(store.state.sessions[0].state,'waiting'); assert.ok(store.state.sessions[0].pending);
  assert.equal(notices.length,1);
});

test('ambient Codex messages do not become names and older history can fill the title without changing live status', t => {
  const {store,emit}=fixture(t);
  emit('UserPromptSubmit',{prompt:'<send_user_message_question_reply>fixture</send_user_message_question_reply>',timestamp:'2026-10-04T12:00:00Z'});
  emit('SessionNamed',{session_name:'<send_user_message_question_reply>fixture</send_user_message_question_reply>',timestamp:'2026-10-04T12:00:00Z'});
  emit('PermissionRequest',{tool_name:'Bash',timestamp:'2026-10-04T12:01:00Z'});
  store.ingest({agent:'claude',session_id:'one',hook_event_name:'UserPromptSubmit',prompt:'Actual session task',timestamp:'2026-10-03T12:00:00Z'},{historical:true});
  assert.equal(store.state.sessions[0].title,'Actual session task');
  assert.equal(store.state.sessions[0].state,'waiting');
  assert.equal(store.state.sessions[0].updatedAt,'2026-10-04T12:01:00.000Z');
});
