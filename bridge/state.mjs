import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, rename, chmod } from 'node:fs/promises';
import { basename, join } from 'node:path';

export const defaults = {
  organization: '', project: '', repository: '', myEmail: '', colleagueEmail: '',
  workItemProject: '', workItemTypes: '',
  authentication: 'interactive', tokenEnvironmentVariable: 'ADO_MCP_AUTH_TOKEN',
  sessionRepositoryPath: '', sessionSubdirectory: 'React.BFF', includeRepositoryRoot: true, agentProvider: 'both',
  notificationSound: true, notifications: true, showNotch: true, importHistory: true,
};
export const blankState = () => ({
  sessions: [], activity: [], pullRequests: [], pipelines: [], workItems: [],
  workItemScopeVersion: 2, connection: 'disconnected', lastSync: null, baselines: {}, errors: [], hookStatus: '',
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
      try {
        const saved = JSON.parse(await readFile(join(this.directory, name + '.json'), 'utf8'));
        this[target] = { ...this[target], ...saved };
        if (name === 'state' && saved.workItemScopeVersion !== 2) {
          // Old caches included a colleague and sprint/due feeds. Never display them as personal items.
          this.state.workItems = [];
          delete this.state.baselines.workItems;
          this.state.workItemScopeVersion = 2;
        }
      }
      catch (e) {
        if (e.code !== 'ENOENT') {
          const backup = name + '.unreadable.' + Date.now() + '.json';
          await rename(join(this.directory, name + '.json'), join(this.directory, backup));
          this.state.errors.push('Could not read ' + name + '; preserved as ' + backup + '.');
        }
      }
    }
    this.settings = Object.fromEntries(Object.entries(this.settings).filter(([key]) => key in defaults));
    this.state.connection = 'disconnected';
    this.state.sessions = this.state.sessions.map(s => ({ ...s, state: ['working', 'thinking', 'waiting'].includes(s.state) ? 'unknown' : s.state }));
  }
  snapshot() {
    const selected = this.settings.agentProvider;
    return { ...this.state, settings: this.settings,
      sessions: this.state.sessions.filter(s => selected === 'both' || s.agent === selected),
      activity: this.state.activity.filter(a => !a.sessionID || selected === 'both' || a.sessionID.startsWith(selected + ':')) };
  }
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
  }
  notice(key, title, body, { url = '', sessionID = '', silent = false, context = {} } = {}) {
    if (this.state.activity.some(x => x.id === key)) return;
    const entry = { id: key, title, body: text(body, 2000), date: now(), read: false, url, sessionID, ...context };
    this.state.activity.unshift(entry);
    if (!silent && this.settings.notifications && (!context.agent || this.settings.agentProvider === 'both' || this.settings.agentProvider === context.agent)) this.onNotice(entry);
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
      if (!['Stop','SessionNamed'].includes(name)) return;
    }
    const isNewer = timestamp >= session.updatedAt;
    const cwd = text(payload.cwd, 4000);
    if (isNewer || !session.cwd) {
      if (cwd) { session.cwd = cwd; session.project = basename(cwd) || cwd; }
      if (payload.branch) session.branch = text(payload.branch, 300);
      for (const field of ['worktree','worktreePath','gitCommonDirectory']) if (payload[field]) session[field] = text(payload[field], 4000);
    }
    session.pending ||= '';
    if (isNewer && payload.session_name) { session.title = text(payload.session_name, 200); session.named = true; }
    const alert = (key, title, pending) => {
      if (historical) return;
      this.notice(key, title, pending, { sessionID: id, context: {
        agent, sessionTitle: session.title || session.project, worktree: session.worktree || session.project,
        branch: session.branch || 'Unknown branch', cwd: session.cwd, pending,
      }});
    };
    if (payload.transcript_path) session.transcriptPath = text(payload.transcript_path, 4000);
    if (!historical) session.source = 'hooks';
    const step = (label) => {
      session.steps.push({ id: eventID || randomUUID(), text: text(label, 1000), date: timestamp });
      session.steps = session.steps.slice(-60);
    };
    const setState = value => { if (isNewer) session.state = value; };
    switch (name) {
      case 'SessionStart': setState('idle'); break;
      case 'SessionNamed': if(payload.session_name) { session.title = text(payload.session_name, 200); session.named = true; } break;
      case 'UserPromptSubmit':
        setState('thinking'); session.pending = ''; session.pendingKey = '';
        if (payload.prompt) { if (!session.title) session.title = text(payload.prompt, 200); step(payload.prompt); }
        break;
      case 'PreToolUse':
        if (/AskUserQuestion|request_user_input/i.test(payload.tool_name || '')) {
          setState('waiting'); session.pending = text(payload.pending_summary || 'Answer the question in the agent', 500);
          session.pendingKey = stableID(id, 'question', payload.tool_use_id || eventID);
          alert(session.pendingKey, 'Input needed', session.pending);
        } else { setState('working'); }
        step(payload.tool_name || 'Working'); break;
      case 'PostToolUse': setState('working'); session.pending = ''; session.pendingKey = ''; break;
      case 'PostToolUseFailure': setState('working'); step('Tool failed: ' + (payload.tool_name || 'tool')); break;
      case 'PermissionRequest':
        setState('waiting');
        session.pending = text(payload.pending_summary || ('Approve ' + (payload.tool_name || 'the requested action') + ' in ' + (agent === 'codex' ? 'Codex' : 'Claude Code')), 500);
        step(session.pending);
        session.pendingKey = stableID(id, 'permission', payload.tool_use_id || eventID);
        alert(session.pendingKey, 'Permission needed', session.pending);
        break;
      case 'Notification': {
        const type = payload.notification_type || '';
        if (!['','permission_prompt','idle_prompt','elicitation_dialog','agent_needs_input'].includes(type)) return;
        if (type === 'idle_prompt' && session.state === 'finished') return;
        const pending = text(payload.message || 'Input needed in the agent', 500);
        const key = type === 'permission_prompt' && session.pendingKey ? session.pendingKey : stableID(id, 'input', pending, session.updatedAt);
        if (session.state === 'waiting' && session.pending === pending) return;
        setState('waiting'); session.pending = pending; session.pendingKey = key; step(pending);
        alert(key, type === 'permission_prompt' ? 'Permission needed' : 'Input needed', pending);
        break;
      }
      case 'Stop': {
        setState('finished'); if (isNewer) { session.pending = ''; session.pendingKey = ''; }
        const answer = text(payload.last_assistant_message || payload.message);
        const answerID = stableID(id, payload.turn_id || '', answer);
        if (answer && !session.answers.some(a => a.id === answerID || a.text === answer && a.date === timestamp)) {
          session.answers.push({ id: answerID, text: answer, date: timestamp });
          session.answers = session.answers.slice(-50);
        }
        alert(answerID, 'Session finished', answer ? text(answer, 500) : 'Response ready — open the session to review.');
        break;
      }
      case 'StopFailure': setState('error'); session.pending = text(payload.error || 'Agent failed; check the terminal.', 500); alert(stableID(id, eventID), 'Session failed', session.pending); break;
      case 'Interrupt': setState('idle'); session.pending = ''; session.pendingKey = ''; break;
      case 'SessionEnd': setState('ended'); session.pending = ''; session.pendingKey = ''; break;
      case 'SubagentStart': step('Subagent started'); break;
      case 'SubagentStop': step('Subagent finished'); break;
      case 'WorktreeReady': case 'BranchPushed':
        alert(stableID(id, name, payload.commit || eventID), name === 'WorktreeReady' ? 'Worktree ready' : 'Branch pushed', name === 'WorktreeReady' ? 'Ready to start work.' : 'Remote branch matches local HEAD.');
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
