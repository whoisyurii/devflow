import { readFile, writeFile, mkdir, chmod, copyFile } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { atomicJSON } from './state.mjs';
const hash = data => createHash('sha256').update(data).digest('hex');
const quote = s => "'" + s.replaceAll("'", "'\\''") + "'";
const events = ['SessionStart','UserPromptSubmit','PreToolUse','PostToolUse','PermissionRequest','Stop','SubagentStart','SubagentStop','SessionEnd'];

export function mergeHooks(original, agent, executable) {
  const root = structuredClone(original);
  if (!root || typeof root !== 'object' || Array.isArray(root)) throw new Error('Hook settings must be a JSON object.');
  if (root.hooks !== undefined && (!root.hooks || typeof root.hooks !== 'object' || Array.isArray(root.hooks))) throw new Error('Existing hooks have an unsupported shape.');
  root.hooks ||= {};
  for (const event of [...events, ...(agent === 'codex' ? ['Interrupt'] : ['PostToolUseFailure','Notification','StopFailure'])]) {
    const groups = root.hooks[event] || [];
    if (!Array.isArray(groups)) throw new Error('Existing hook groups have an unsupported shape.');
    // Keep every hook owned by another tool, including upstream Coucou.
    const kept = groups.map(group => {
      if (!group || !Array.isArray(group.hooks)) throw new Error('Existing hook group has an unsupported shape.');
      return { ...group, hooks: group.hooks.filter(h => !(typeof h.command === 'string' && h.command.includes(executable))) };
    }).filter(group => group.hooks.length);
    kept.push({ hooks: [{ type: 'command', command: '/usr/bin/python3 ' + quote(executable) + ' --agent ' + agent, timeout: 2 }] });
    root.hooks[event] = kept;
  }
  return root;
}
export class Hooks {
  constructor(directory, home = homedir()) { this.directory = directory; this.home = home; this.pending = null; }
  async preview() {
    const executable = join(this.directory,'devflow-hook.py');
    const changes = [];
    for (const [agent, path] of [['claude',join(this.home,'.claude','settings.json')],['codex',join(this.home,'.codex','hooks.json')]]) {
      let raw = ''; try { raw = await readFile(path,'utf8'); } catch(e) { if(e.code !== 'ENOENT') throw e; }
      const modified = mergeHooks(raw ? JSON.parse(raw) : {},agent,executable);
      changes.push({ path, original: hash(raw), modified });
    }
    this.pending = changes;
    return changes.map(c => c.path + '\n' + JSON.stringify({hooks:c.modified.hooks},null,2)).join('\n\n');
  }
  async install() {
    if (!this.pending) throw new Error('Preview the hook changes first.');
    // Check every file before writing either one.
    for (const c of this.pending) {
      let current = ''; try { current = await readFile(c.path,'utf8'); } catch(e) { if(e.code!=='ENOENT') throw e; }
      if (hash(current)!==c.original) throw new Error('Hook settings changed since preview. Preview them again.');
    }
    await mkdir(this.directory,{recursive:true,mode:0o700});
    for (const script of ['devflow-hook.py','devflow-event.py']) {
      await copyFile(fileURLToPath(new URL('./'+script,import.meta.url)),join(this.directory,script));
      await chmod(join(this.directory,script),0o700);
    }
    const backups = [];
    for (const c of this.pending) {
      await mkdir(join(c.path,'..'),{recursive:true});
      try {
        const backup=c.path+'.devflow-backup-'+Date.now(); await copyFile(c.path,backup); await chmod(backup,0o600); backups.push(backup);
      } catch(e) { if(e.code!=='ENOENT') throw e; }
      await atomicJSON(c.path,c.modified);
    }
    this.pending=null;
    return { message: 'Hooks installed. In Codex, open Settings → Hooks (or /hooks) and trust the DevFlow entries. Start a new Claude Code session to load its hooks.', backups };
  }
}
