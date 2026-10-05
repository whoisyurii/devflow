import { realpath, readFile, stat, open, readdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
const canonical = async path => realpath(path).catch(() => resolve(path));
const within = (root, path) => { const r = relative(root, path); return r === '' || (!r.startsWith('..' + sep) && r !== '..' && !isAbsolute(r)); };

export async function transcriptName(path, agent, home = homedir()) {
  if (!path || !isAbsolute(path)) return '';
  let handle;
  try {
    const allowed = await canonical(join(home, agent === 'codex' ? '.codex/sessions' : '.claude/projects'));
    const file = await realpath(path);
    if (!within(allowed, file)) return '';
    handle = await open(file, 'r');
    const size = (await handle.stat()).size, length = Math.min(size, 65536);
    const head = Buffer.alloc(length), tail = Buffer.alloc(length);
    await handle.read(head, 0, length, 0);
    await handle.read(tail, 0, length, Math.max(0, size - length));
    const lines = [...head.toString('utf8').split('\n'), ...tail.toString('utf8').split('\n')];
    for (const line of lines.reverse()) {
      let row; try { row = JSON.parse(line); } catch { continue; }
      const name = agent === 'claude' && row.type === 'custom-title' ? row.customTitle
        : row.type === 'event_msg' && row.payload?.type === 'thread_name_updated' ? row.payload.thread_name || row.payload.name : '';
      if (typeof name === 'string' && name.trim()) return name.slice(0, 200);
    }
  } catch {} finally { await handle?.close(); }
  return '';
}

export class SessionScope {
  constructor(settings) { this.settings = settings; this.cache = new Map(); this.worktrees = null; }
  async roots(anchor, refresh = false) {
    if (!refresh && this.worktrees?.common === anchor.gitCommonDirectory && Date.now() - this.worktrees.at < 5000) return this.worktrees.roots;
    const roots = [anchor.worktreePath];
    if (basename(anchor.gitCommonDirectory) === '.git') roots.push(dirname(anchor.gitCommonDirectory));
    const registry = join(anchor.gitCommonDirectory, 'worktrees');
    for (const name of (await readdir(registry).catch(() => [])).slice(0,1000)) {
      try {
        const pointer = (await readFile(join(registry, name, 'gitdir'), 'utf8')).trim();
        if (isAbsolute(pointer)) roots.push(await canonical(dirname(pointer)));
      } catch {}
    }
    this.worktrees = { common: anchor.gitCommonDirectory, at: Date.now(), roots };
    return roots;
  }
  async inspect(cwd, refresh = false) {
    if (!cwd || !isAbsolute(cwd)) return null;
    const cached = this.cache.get(cwd);
    if (!refresh && cached && Date.now() - cached.at < 5000) return cached.value;
    let value = null;
    try {
      const path = await canonical(cwd);
      if (!(await stat(path)).isDirectory()) throw new Error('Missing session folder');
      // Read Git's documented worktree metadata directly. A GUI-launched Git
      // process can stall in getcwd while traversing macOS-protected parents.
      // This reads only .git/commondir/HEAD and never scans source files.
      let root = path;
      while (true) {
        const marker = join(root, '.git');
        const entry = await stat(marker).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
        if (entry) {
          let gitDir = marker;
          if (entry.isFile()) {
            const pointer = (await readFile(marker, 'utf8')).trim().match(/^gitdir: (.+)$/);
            if (!pointer) throw new Error('Invalid Git worktree pointer');
            gitDir = resolve(root, pointer[1]);
          }
          const commonPath = await readFile(join(gitDir, 'commondir'), 'utf8')
            .catch(error => { if (error.code === 'ENOENT') return ''; throw error; });
          const common = await realpath(commonPath.trim() ? resolve(gitDir, commonPath.trim()) : gitDir);
          const head = (await readFile(join(gitDir, 'HEAD'), 'utf8')).trim();
          const branch = head.startsWith('ref: refs/heads/') ? head.slice(16)
            : /^[a-f0-9]{40,64}$/i.test(head) ? 'detached ' + head.slice(0,7) : 'Unknown branch';
          value = { cwd: path, worktreePath: root, worktree: basename(root), gitCommonDirectory: common, branch };
          break;
        }
        const parent = dirname(root);
        if (parent === root) break;
        root = parent;
      }
    } catch {}
    this.cache.set(cwd, { value, at: Date.now() });
    if (this.cache.size > 1000) this.cache.delete(this.cache.keys().next().value);
    return value;
  }
  async match(cwd, { refresh = false, fallback = null } = {}) {
    const settings = this.settings();
    const anchor = await this.inspect(settings.sessionRepositoryPath);
    if (!anchor) return null;
    if (!cwd || !isAbsolute(cwd)) return null;
    const path = await canonical(cwd);
    const verifiedFallback = fallback?.gitCommonDirectory === anchor.gitCommonDirectory && fallback.cwd === path;
    // Reject unrelated projects before opening their Git metadata. Enumerate
    // only this repository's worktree registry, including trees outside its root.
    if (!(await this.roots(anchor, refresh)).some(root => within(root, path)) && !verifiedFallback) return null;
    const info = await this.inspect(cwd, refresh)
      || (fallback?.cwd && cwd && fallback.cwd === await canonical(cwd) ? fallback : null);
    if (!info?.cwd || !info.worktreePath || info.gitCommonDirectory !== anchor.gitCommonDirectory || !within(info.worktreePath, info.cwd)) return null;
    const subdirectory = settings.sessionSubdirectory.trim();
    const allowed = resolve(info.worktreePath, subdirectory || '.');
    if (!within(info.worktreePath, allowed)) return null;
    if (!within(allowed, info.cwd) && !(settings.includeRepositoryRoot && info.cwd === info.worktreePath)) return null;
    return info;
  }
}

export class SessionMonitor {
  constructor(store) { this.store = store; this.scope = new SessionScope(() => store.settings); }
  async ingest(payload, options = {}) {
    if (payload.agent_id && !['SubagentStart','SubagentStop'].includes(payload.hook_event_name)) return false;
    const agent = payload.agent === 'codex' ? 'codex' : 'claude';
    const prior = this.store.state.sessions.find(s => s.id === agent + ':' + (payload.session_id || payload.sessionId));
    const critical = ['Stop','PermissionRequest','Notification','WorktreeReady','BranchPushed','SessionStart'].includes(payload.hook_event_name);
    const info = await this.scope.match(payload.cwd || prior?.cwd, { refresh: !options.historical && critical, fallback: prior });
    if (!info) return false;
    const name = !options.historical && critical ? await transcriptName(payload.transcript_path || prior?.transcriptPath, agent) : '';
    this.store.ingest({ ...payload, ...info, session_name: payload.session_name || name,
      branch: options.historical && payload.branch ? payload.branch : info.branch }, options);
    return true;
  }
  async reconcile() {
    this.scope.cache.clear();
    this.scope.worktrees = null;
    const kept = [];
    for (const session of this.store.state.sessions) {
      const info = await this.scope.match(session.cwd, { fallback: session });
      if (info) kept.push({ ...session, ...info, branch: session.branch || info.branch });
    }
    this.store.state.sessions = kept;
    const ids = new Set(kept.map(s => s.id));
    this.store.state.activity = this.store.state.activity.filter(a => !a.sessionID || ids.has(a.sessionID));
  }
}
