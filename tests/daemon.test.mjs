import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createConnection } from 'node:net';
import { createInterface } from 'node:readline';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

async function launch(directory) {
  const child=spawn(process.execPath,[fileURLToPath(new URL('../bridge/main.mjs',import.meta.url)),'--data-dir',directory,'--no-history'],{stdio:['pipe','pipe','pipe']});
  const requests=new Map();let count=0;let ready;
  const started=new Promise(resolve=>{ready=resolve;});
  const exited=new Promise(resolve=>child.on('exit',resolve));
  child.stderr.on('data',()=>{});
  createInterface({input:child.stdout}).on('line',line=>{
    const message=JSON.parse(line);
    if(message.type==='snapshot')ready();
    if(message.type==='response'){
      const request=requests.get(message.id);requests.delete(message.id);
      if(message.error)request?.reject(new Error(message.error));else request?.resolve(message.result);
    }
  });
  await Promise.race([started,new Promise((_,reject)=>{const timeout=setTimeout(()=>{child.kill();reject(new Error('Bridge failed to start'));},5000);timeout.unref();})]);
  return {
    call(method,params={}) {const id=String(++count);return new Promise((resolve,reject)=>{requests.set(id,{resolve,reject});child.stdin.write(JSON.stringify({id,method,params})+'\n');});},
    async close(){child.stdin.end();await exited;},
  };
}
function event(directory,payload) {
  return new Promise((resolve,reject)=>{
    const socket=createConnection(join(directory,'events.sock'));
    socket.on('connect',()=>socket.write(JSON.stringify(payload)+'\n'));
    socket.on('end',resolve);socket.on('error',reject);
  });
}
test('real bridge handles Unix socket events, persists answers, and restores unread state',{timeout:15000},async()=>{
  const directory=await mkdtemp('/tmp/df-');let bridge;
  try{
    bridge=await launch(directory);
    assert.equal((await stat(join(directory,'events.sock'))).mode & 0o777,0o600);
    await event(directory,{agent:'codex',session_id:'abc',hook_event_name:'Stop',last_assistant_message:'Complete\nanswer',turn_id:'one'});
    let state=await bridge.call('snapshot');assert.equal(state.sessions.length,1);assert.equal(state.activity.length,1);
    await bridge.call('markRead',{id:state.activity[0].id});
    await assert.rejects(bridge.call('executeShell',{command:'should never run'}),/Unknown/);
    await bridge.close();bridge=null;
    bridge=await launch(directory);state=await bridge.call('snapshot');
    assert.equal(state.sessions[0].answers[0].text,'Complete\nanswer');assert.equal(state.activity[0].read,true);
  }finally{if(bridge)await bridge.close();await rm(directory,{recursive:true,force:true});}
});
