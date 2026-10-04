import { createServer, createConnection } from 'node:net';
import { chmod, unlink } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { Store } from './state.mjs';
import { ADO, attachBuildChecks } from './ado.mjs';
import { Hooks } from './hooks.mjs';
import { History } from './history.mjs';
import { SessionMonitor } from './session-scope.mjs';

const argument = key => { const i=process.argv.indexOf(key); return i<0 ? null : process.argv[i+1]; };
const directory = argument('--data-dir') || process.env.DEVFLOW_DATA_DIR || join(homedir(),'Library','Application Support','DevFlow');
const output = value => process.stdout.write(JSON.stringify(value)+'\n');
const store = new Store(directory, data => output({type:'snapshot',data}), data => output({type:'notice',data}));
await store.load();
const hooks = new Hooks(directory);
const monitor = new SessionMonitor(store);
await monitor.reconcile();
const history = new History(store, undefined, monitor);
let eventQueue = Promise.resolve();
const ado = new ADO();
let timer, busy = false, connected = false, failures = 0, generation = 0;

async function refresh() {
  if (busy || !connected) return;
  busy=true; clearTimeout(timer);
  const currentGeneration=generation;
  store.state.connection='refreshing'; store.publish();
  try {
    const results = await Promise.allSettled([ado.pullRequests(),ado.pipelines(),ado.workItems()]);
    if (currentGeneration!==generation) return;
    const keys=['pullRequests','pipelines','workItems'];
    const errors=[];
    for(let i=0;i<results.length;i++) {
      const result=results[i];
      if(result.status==='fulfilled') store.updateADO(keys[i],result.value);
      else errors.push(keys[i]+': '+String(result.reason?.message || 'Request failed').slice(0,600));
    }
    store.state.pullRequests=attachBuildChecks(store.state.pullRequests,store.state.pipelines);
    store.state.errors=errors;
    if (errors.length<3) store.state.lastSync=new Date().toISOString();
    store.state.connection=errors.length ? 'attention' : 'connected';
    failures=errors.length ? failures+1 : 0;
  } finally {
    busy=false;
    if(currentGeneration===generation) {
      store.publish();
      const active=store.state.pipelines.some(b=>['running','queued'].includes(b.status));
      const delay=failures ? Math.min(900000,60000*2**Math.min(failures-1,4)) : active ? 45000 : 180000;
      if(connected) timer=setTimeout(refresh,delay);
    }
  }
}

const socketPath=join(directory,'events.sock');
const server=createServer(connection=>{
  let buffer=''; connection.setTimeout(1000,()=>connection.destroy());
  connection.on('error',()=>{});
  connection.on('data',chunk=>{
    buffer+=chunk.toString('utf8');
    if(Buffer.byteLength(buffer)>1024*1024) return connection.destroy();
    const i=buffer.indexOf('\n');
    if(i<0) return;
    try {
      const payload = JSON.parse(buffer.slice(0,i));
      eventQueue = eventQueue.then(() => monitor.ingest(payload)).catch(() => {});
    } catch {}
    connection.end();
  });
});
const listen=()=>new Promise((resolve,reject)=>{
  server.once('error',reject); server.listen(socketPath,()=>{server.removeListener('error',reject);resolve();});
});
try { await listen(); }
catch(error) {
  if(error.code!=='EADDRINUSE') throw error;
  const live=await new Promise(resolve=>{
    const socket=createConnection(socketPath);socket.setTimeout(200);
    socket.once('connect',()=>{socket.destroy();resolve(true);});
    socket.once('error',()=>resolve(false));socket.once('timeout',()=>{socket.destroy();resolve(true);});
  });
  if(live) {output({type:'fatal',message:'DevFlow is already running for this user.'});process.exit(1);}
  await unlink(socketPath); await listen();
}
await chmod(socketPath,0o600);
server.on('error',e=>{store.state.errors=['Local event listener: '+e.message];store.publish();});
store.publish();
if(!process.argv.includes('--no-history')) await history.importRecent();
const historyTimer=setInterval(()=>history.importRecent().catch(()=>{}),60000);

async function command(message) {
  const p=message.params||{};
  switch(message.method) {
    case 'snapshot': await eventQueue; return store.snapshot();
    case 'configure': {
      const previous=store.settings;
      const adoChanged=['organization','project','repository','myEmail','colleagueEmail','workItemProject','workItemTypes','authentication','tokenEnvironmentVariable'].some(k=>p[k]!==undefined&&previous[k]!==p[k]);
      if(adoChanged) {connected=false;generation++;clearTimeout(timer);await ado.close();}
      await store.saveSettings(p);
      if(['organization','project','repository','myEmail','colleagueEmail','workItemProject','workItemTypes'].some(k=>previous[k]!==store.settings[k])) {
        store.state.pullRequests=[];store.state.pipelines=[];store.state.workItems=[];store.state.lastSync=null;store.state.baselines={};
      }
      if(['sessionRepositoryPath','sessionSubdirectory','includeRepositoryRoot'].some(k=>previous[k]!==store.settings[k])) {
        await eventQueue; await monitor.reconcile(); history.seen.clear(); await history.importRecent();
      }
      if(adoChanged) store.state.connection='disconnected';
      store.publish();return true;
    }
    case 'connect': {
      if(busy) throw new Error('Wait for the current connection attempt to finish, or disconnect.');
      busy=true;const current=++generation;clearTimeout(timer);
      store.state.connection='connecting';store.state.errors=[];store.publish();
      try {
        await ado.connect(store.settings);
        if(current!==generation) return false;
        connected=true;
      } catch(e) {
        if(current===generation) {connected=false;store.state.connection='attention';store.state.errors=[e.message];store.publish();}
        throw e;
      } finally {busy=false;}
      await refresh();return true;
    }
    case 'disconnect': generation++;connected=false;clearTimeout(timer);await ado.close();store.state.connection='disconnected';store.publish();return true;
    case 'refresh': if(!connected) return command({method:'connect'});await refresh();return true;
    case 'previewHooks': return hooks.preview();
    case 'installHooks': {const result=await hooks.install();store.state.hookStatus=result.message;store.publish();return result;}
    case 'importHistory': await history.importRecent();return true;
    case 'markRead': for(const item of store.state.activity) if(!p.id||item.id===p.id)item.read=true;store.publish();return true;
    default: throw new Error('Unknown DevFlow operation.');
  }
}
createInterface({input:process.stdin}).on('line',line=>{
  let message;try{message=JSON.parse(line);}catch{return;}
  if(!message.id)return;
  command(message).then(result=>output({type:'response',id:message.id,result}),error=>output({type:'response',id:message.id,error:String(error.message||error).slice(0,1000)}));
}).on('close',()=>shutdown());
let closing=false;
async function shutdown() {
  if(closing)return;closing=true;connected=false;clearTimeout(timer);clearInterval(historyTimer);
  await ado.close();server.close();await eventQueue;await store.flush().catch(()=>{});await unlink(socketPath).catch(()=>{});process.exit(0);
}
process.on('SIGTERM',()=>shutdown());process.on('SIGINT',()=>shutdown());
