import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
const exec = promisify(execFile);
const allowed = new Set(['repo_repository', 'repo_pull_request', 'pipelines_build', 'wit_query', 'wit_work_item']);
const escapeWIQL = s => s.replaceAll("'", "''");
const branch = s => (s || '').replace(/^refs\/heads\//, '');
const email = u => (u?.uniqueName || '').toLowerCase();

export function parseToolResult(result) {
  if (result.isError) {
    let message=result.content?.find(c => c.type === 'text')?.text || 'Azure DevOps request failed';
    message=message.replace(/^<<[^\n]*>>\n/, '').replace(/\n<<\/[^\n]*>>$/, '');
    throw new Error(message.slice(0,500));
  }
  if (result.structuredContent) return result.structuredContent;
  const raw = result.content?.filter(c => c.type === 'text').map(c => c.text).join('\n') || '';
  try { return JSON.parse(raw); } catch {}
  // Microsoft wraps untrusted API content in a random, labelled delimiter.
  const start = raw.search(/^[\[{]/m);
  const end = raw.lastIndexOf('\n<</');
  if (start >= 0 && end > start) return JSON.parse(raw.slice(start, end));
  throw new Error('Azure DevOps returned an unexpected response format.');
}
export function dayBounds(date = new Date()) {
  const start = new Date(date); start.setHours(0,0,0,0);
  const end = new Date(start); end.setDate(end.getDate() + 1);
  return [start.toISOString(), end.toISOString()];
}
export function buildState(build) {
  const statuses = { 1: 'running', 2: 'completed', 4: 'canceling', 8: 'queued', 32: 'postponed', 0: 'unknown' };
  const results = { 2: 'succeeded', 4: 'partiallySucceeded', 8: 'failed', 32: 'canceled' };
  const status = typeof build.status === 'number' ? statuses[build.status] : ({ inProgress: 'running', notStarted: 'queued' }[build.status] || build.status);
  return status === 'completed' ? (results[build.result] || build.result || 'completed') : (status || 'unknown');
}
export async function mapLimit(items, limit, operation) {
  const results = new Array(items.length); let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) { const index = next++; results[index] = await operation(items[index]); }
  }));
  return results;
}

export class ADO {
  constructor() { this.client = null; this.transport = null; }
  async connect(settings) {
    await this.close();
    if (!/^[a-zA-Z0-9][a-zA-Z0-9-]*$/.test(settings.organization)) throw new Error('Enter your Azure DevOps organization name, without a URL.');
    if (!settings.project || !settings.repository) throw new Error('Enter a project and repository in Settings.');
    if (!['interactive','azcli','pat','envvar'].includes(settings.authentication)) throw new Error('Unsupported authentication method.');
    const environment = { ...process.env, ado_mcp_project: settings.project, ADO_MCP_LOG_LEVEL: 'error' };
    if (settings.authentication === 'pat') {
      const { stdout } = await exec('/usr/bin/security', ['find-generic-password','-s','devflow.azure-devops','-a',settings.organization,'-w']).catch(() => { throw new Error('No DevFlow PAT found in Keychain. Save one in Settings or choose Microsoft sign-in.'); });
      environment.PERSONAL_ACCESS_TOKEN = Buffer.from('devflow:' + stdout.trim()).toString('base64');
    }
    if (settings.authentication === 'envvar') {
      const name = settings.tokenEnvironmentVariable;
      if (!/^[A-Z_][A-Z0-9_]*$/.test(name || '') || !process.env[name]) throw new Error('The configured token environment variable is unavailable to this app.');
      environment.ADO_MCP_AUTH_TOKEN = process.env[name];
    }
    this.transport = new StdioClientTransport({
      command: process.execPath,
      args: [fileURLToPath(new URL('./node_modules/@azure-devops/mcp/dist/index.js', import.meta.url)), settings.organization,
        '--authentication', settings.authentication, '-d', 'core', 'repositories', 'work-items', 'pipelines'],
      env: environment, stderr: 'pipe',
    });
    this.transport.stderr?.on('data', () => {}); // Never send library/auth logs or tokens to the UI.
    this.client = new Client({ name: 'DevFlow', version: '0.1.0' });
    await this.client.connect(this.transport);
    // Resolve the repository first: serializes interactive authentication before parallel reads.
    this.repository = await this.call('repo_repository', { action: 'get', project: settings.project, repositoryNameOrId: settings.repository });
    this.settings = settings;
  }
  async close() {
    const client = this.client; this.client = null;
    if (client) await client.close().catch(() => {});
    this.transport = null;
  }
  async call(name, args) {
    if (!allowed.has(name)) throw new Error('Unsupported Azure DevOps operation.');
    if (!this.client) throw new Error('Connect to Azure DevOps in Settings.');
    return parseToolResult(await this.client.callTool({ name, arguments: args }, undefined, { timeout: 120000 }));
  }
  async listPRs(filter = {}) {
    const results = [];
    for (let skip = 0; skip < 2000; skip += 100) {
      const page = await this.call('repo_pull_request', { action: 'list', project: this.settings.project, repositoryId: this.repository.id,
        status: 'Active', top: 100, skip, ...filter });
      if (!Array.isArray(page)) throw new Error('Invalid pull request list.');
      results.push(...page); if (page.length < 100) return results;
    }
    throw new Error('More than 2,000 active PRs; narrow the selected repository.');
  }
  baseURL(project = this.settings.project) { return 'https://dev.azure.com/' + this.settings.organization + '/' + encodeURIComponent(project); }
  async pullRequests() {
    const s = this.settings;
    const [all, mine, reviews] = await Promise.all([
      this.listPRs(), this.listPRs(s.myEmail ? { created_by_user: s.myEmail } : { created_by_me: true }),
      this.listPRs(s.myEmail ? { user_is_reviewer: s.myEmail } : { i_am_reviewer: true }),
    ]);
    const myIDs = new Set(mine.map(p => p.pullRequestId));
    const reviewIDs = new Set(reviews.map(p => p.pullRequestId));
    return mapLimit(all, 4, async p => {
      const detail = await this.call('repo_pull_request', { action: 'get', project: s.project, repositoryId: this.repository.id, pullRequestId: p.pullRequestId });
      const reviewers = (detail.reviewers || []).map(r => ({ name: r.displayName || r.uniqueName || 'Reviewer', vote: r.vote || 0 }));
      const votes = reviewers.map(r => r.vote);
      const review = votes.includes(-10) ? 'Changes requested' : votes.includes(-5) ? 'Waiting for author' : votes.some(v => v >= 5) ? 'Has approvals' : 'Awaiting review';
      const buckets = ['all'];
      if (myIDs.has(p.pullRequestId)) buckets.push('mine');
      if (reviewIDs.has(p.pullRequestId)) buckets.push('review');
      if (s.colleagueEmail && email(p.createdBy) === s.colleagueEmail.toLowerCase()) buckets.push('colleague');
      return { id: String(p.pullRequestId), title: p.title, author: p.createdBy?.displayName || '',
        branch: branch(p.sourceRefName), target: branch(p.targetRefName), draft: Boolean(p.isDraft), review,
        reviewRequested: reviewIDs.has(p.pullRequestId), reviewers, buckets, checks: 'Not loaded',
        sourceCommit: detail.lastMergeSourceCommit?.commitId || '', mergeCommit: detail.lastMergeCommit?.commitId || '',
        mergeStatus: String(detail.mergeStatus || ''),
        url: this.baseURL() + '/_git/' + encodeURIComponent(s.repository) + '/pullrequest/' + p.pullRequestId };
    });
  }
  async pipelines() {
    const common = { action: 'list', project: this.settings.project, repositoryId: this.repository.id, repositoryType: 'TfsGit', top: 100, queryOrder: 'QueueTimeDescending' };
    const [recent, running, queued] = await Promise.all([
      this.call('pipelines_build', common), this.call('pipelines_build', { ...common, statusFilter: 1 }), this.call('pipelines_build', { ...common, statusFilter: 8 }),
    ]);
    return [...new Map([...running,...queued,...recent].map(b => [b.id,b])).values()].map(b => ({
      id: String(b.id), definitionID: String(b.definition?.id || ''), name: b.definition?.name || 'Pipeline', number: b.buildNumber || '', status: buildState(b),
      branch: branch(b.sourceBranch), commit: b.sourceVersion || '', requestedBy: b.requestedFor?.displayName || '',
      date: b.queueTime || '', startedAt: b.startTime || '', finishedAt: b.finishTime || '',
      url: this.baseURL() + '/_build/results?buildId=' + b.id,
    })).sort((a,b) => b.date.localeCompare(a.date));
  }
  async query(wiql) {
    return this.call('wit_query', { action: 'wiql', project: this.settings.workItemProject || this.settings.project, wiql, top: 200, timePrecision: true });
  }
  async workItems() {
    const s = this.settings;
    const project = s.workItemProject || s.project;
    const types = (s.workItemTypes || '').split(',').map(t => t.trim()).filter(Boolean);
    const base = 'SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND '
      + (types.length ? '[System.WorkItemType] IN (' + types.map(t => "'" + escapeWIQL(t) + "'").join(', ') + ') AND ' : '');
    const assignee = s.myEmail ? "'" + escapeWIQL(s.myEmail) + "'" : '@me';
    const personal = base + '[System.AssignedTo] = ' + assignee
      + " AND [System.State] NOT IN ('Closed', 'Done', 'Removed')";
    const [start,end] = dayBounds();
    const queries = {
      mine: personal + ' ORDER BY [System.ChangedDate] DESC',
      today: personal + " AND [System.CreatedDate] >= '" + start + "' AND [System.CreatedDate] < '" + end + "' ORDER BY [System.CreatedDate] DESC",
    };
    const groups = await Promise.all(Object.entries(queries).map(async ([key,wiql]) => [key,(await this.query(wiql)).workItems || []]));
    const ids = [...new Set(groups.flatMap(([,rows]) => rows.map(r => r.id)))];
    const items = [];
    for (let i=0; i<ids.length; i+=200) {
      const page = await this.call('wit_work_item', { action: 'get_batch', project, ids: ids.slice(i,i+200),
        fields: ['System.Id','System.Title','System.State','System.WorkItemType','System.AssignedTo','System.CreatedDate','System.ChangedDate','System.IterationPath'] });
      items.push(...page);
    }
    items.sort((a,b) => (b.fields?.['System.ChangedDate'] || '').localeCompare(a.fields?.['System.ChangedDate'] || ''));
    return items.map(w => ({ id: String(w.id), title: w.fields?.['System.Title'] || '', state: w.fields?.['System.State'] || '',
      type: w.fields?.['System.WorkItemType'] || '', assignedTo: typeof w.fields?.['System.AssignedTo'] === 'string'
        ? w.fields['System.AssignedTo'].replace(/\s*<[^>]+>$/, '') : w.fields?.['System.AssignedTo']?.displayName || '',
      iteration: w.fields?.['System.IterationPath'] || '', createdAt: w.fields?.['System.CreatedDate'] || '',
      buckets: groups.filter(([,rows]) => rows.some(r => r.id === w.id)).map(([key]) => key),
      url: this.baseURL(project) + '/_workitems/edit/' + w.id,
    }));
  }
}

export function attachBuildChecks(prs, builds) {
  return prs.map(p => {
    const candidates = builds.filter(b => b.branch === 'refs/pull/' + p.id + '/merge' && p.mergeCommit && b.commit === p.mergeCommit)
      .sort((a,b) => b.date.localeCompare(a.date));
    const matching = [...new Map(candidates.reverse().map(b => [b.definitionID || b.name,b])).values()];
    const statuses = matching.map(b => b.status);
    const checks = statuses.includes('failed') ? 'Build failed' : statuses.some(s => ['queued','running'].includes(s)) ? 'Build running'
      : statuses.includes('succeeded') ? 'Build passed' : 'No matching build';
    return { ...p, checks };
  });
}
