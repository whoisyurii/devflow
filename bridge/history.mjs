import { opendir, stat, open } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { stableID } from './state.mjs';

async function collect(directory, depth = 0) {
  if (depth > 6) return [];
  const files = [];
  let entries; try { entries = await opendir(directory); } catch { return files; }
  for await (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory() && entry.name !== 'subagents') files.push(...await collect(path, depth + 1));
    else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
      try { const info = await stat(path); files.push({ path, modified: info.mtimeMs, size: info.size }); } catch {}
    }
  }
  return files;
}
export function historyEvents(lines, agent, path) {
  if (agent === 'codex' && auxiliaryCodexSession(lines)) return [];
  const events = []; let id = ''; let cwd = ''; let branch = ''; let turn = ''; let lastTimestamp;
  const emit = (event, timestamp, extra = {}) => {
    if (id) events.push({ agent, session_id: id, cwd, branch, timestamp, transcript_path: path,
      turn_id: turn, hook_event_name: event, event_id: stableID(path, timestamp || '', event, extra.last_assistant_message || extra.prompt || extra.session_name || ''), ...extra });
  };
  for (const line of lines) {
    let r; try { r = JSON.parse(line); } catch { continue; }
    if (r.timestamp) lastTimestamp = r.timestamp;
    if (agent === 'codex') {
      const p = r.payload || {};
      if (r.type === 'session_meta') { id = p.id || p.session_id; cwd = p.cwd || ''; branch = p.git?.branch || ''; emit('SessionStart', r.timestamp); }
      if (r.type === 'event_msg' && p.type === 'thread_name_updated') emit('SessionNamed', r.timestamp, { session_name: p.thread_name || p.name || '' });
      if (r.type === 'turn_context') { turn = p.turn_id || turn; cwd = p.cwd || cwd; }
      if (r.type === 'event_msg' && p.type === 'task_started') { turn = p.turn_id || turn; emit('PreToolUse', r.timestamp, { tool_name: 'Session active' }); }
      if (r.type === 'event_msg' && p.type === 'user_message') emit('UserPromptSubmit', r.timestamp, { prompt: p.message || '' });
      if (r.type === 'response_item' && p.type === 'message' && p.role === 'user') {
        const prompt = (p.content || []).filter(x => x.type === 'input_text').map(x => x.text).join('\n').trim();
        const ambient = /^<(?:skill|in-app-browser-context|realtime_delegation|environment_context|permissions|app-context|turn_aborted|send_user_message_question_reply)\b/.test(prompt);
        if (prompt && !prompt.startsWith('# AGENTS.md') && !ambient)
          emit('UserPromptSubmit', r.timestamp, { prompt });
      }
      if (r.type === 'event_msg' && p.type === 'task_complete') { turn = p.turn_id || turn; emit('Stop', r.timestamp, { last_assistant_message: p.last_agent_message || p.last_assistant_message || '' }); }
      if (r.type === 'event_msg' && ['turn_aborted','task_interrupted'].includes(p.type)) emit('Interrupt', r.timestamp);
      if (r.type === 'response_item' && p.type === 'message' && p.role === 'assistant' && p.phase === 'final_answer')
        emit('Stop', r.timestamp, { last_assistant_message: (p.content || []).filter(x => x.type === 'output_text').map(x => x.text).join('\n') });
    } else {
      if (r.isSidechain) continue;
      id = r.sessionId || r.session_id || id; cwd = r.cwd || cwd; branch = r.gitBranch || branch;
      if (r.type === 'custom-title') emit('SessionNamed', r.timestamp || lastTimestamp, { session_name: r.customTitle || '' });
      if (r.type === 'user' && !r.isMeta && typeof r.message?.content === 'string') emit('UserPromptSubmit', r.timestamp, { prompt: r.message.content });
      if (r.type === 'assistant' && r.message?.stop_reason === 'end_turn') {
        turn = r.message.id || r.uuid || '';
        const answer = (r.message.content || []).filter(c => c.type === 'text').map(c => c.text).join('\n');
        if (answer) emit('Stop', r.timestamp, { last_assistant_message: answer });
      }
    }
  }
  return events;
}
function auxiliaryCodexSession(lines) {
  for (const line of lines) {
    try { const row=JSON.parse(line); if(row.type==='session_meta') return Boolean(row.payload?.source?.subagent); } catch {}
  }
  return false;
}
export class History {
  constructor(store, home = homedir(), monitor = null) { this.store = store; this.home = home; this.monitor = monitor; this.seen = new Map(); }
  async importRecent() {
    if (!this.store.settings.importHistory || this.running) return;
    this.running = true;
    const revision = this.store.revision;
    let changed = false;
    try {
      for (const [agent, directory] of [['codex',join(this.home,'.codex','sessions')],['claude',join(this.home,'.claude','projects')]]) {
        const files = (await collect(directory)).sort((a,b) => b.modified-a.modified).slice(0,2000);
        let admitted = 0;
        for (const file of files) {
          if (admitted >= 100) break;
          const seen = this.seen.get(file.path);
          if (seen?.modified === file.modified) { if(seen.admitted) admitted++; continue; }
          this.seen.set(file.path,{modified:file.modified, admitted:false});
          let handle;
          try {
            handle = await open(file.path, 'r');
            const head = Buffer.alloc(Math.min(65536,file.size)); await handle.read(head,0,head.length,0);
            const headLines = head.toString('utf8').split('\n');
            if (file.size > head.length) headLines.pop();
            const first = historyEvents(headLines,agent,file.path).find(e => e.cwd);
            if (this.monitor && (!first || !await this.monitor.scope.match(first.cwd))) continue;
            admitted++; this.seen.set(file.path,{modified:file.modified, admitted:true});
            // Bounded I/O: session metadata plus the most recent 2 MiB of very large transcripts.
            const bytes = Math.min(file.size, 2 * 1024 * 1024);
            const tail = Buffer.alloc(bytes); await handle.read(tail,0,bytes,file.size-bytes);
            let lines = tail.toString('utf8').split('\n');
            if (file.size > bytes) {
              lines.shift();
              lines = [...headLines,...lines];
            }
            if(agent==='codex' && auxiliaryCodexSession(lines)) {
              // Internal reviewer/subagent transcripts are not user chats. Remove
              // any old imported cache entry as well; never alter source transcripts.
              const prior = this.store.state.sessions.length;
              this.store.state.sessions=this.store.state.sessions.filter(s=>s.source!=='history'||s.transcriptPath!==file.path);
              changed ||= prior !== this.store.state.sessions.length;
              continue;
            }
            for (const event of historyEvents(lines,agent,file.path)) {
              if (this.monitor) await this.monitor.ingest(event,{historical:true});
              else this.store.ingest(event,{historical:true});
            }
          } catch {} finally { await handle?.close(); }
        }
      }
      // A stale transcript cannot prove a process is still running.
      for (const session of this.store.state.sessions) {
        if (session.source === 'history' && ['working','thinking'].includes(session.state) && Date.now()-Date.parse(session.updatedAt)>180000) {
          session.state = 'unknown'; changed = true;
        }
      }
      if (changed || this.store.revision !== revision) this.store.publish();
    } finally { this.running = false; }
  }
}
