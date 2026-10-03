import test from 'node:test';
import assert from 'node:assert/strict';
import { ADO } from '../bridge/ado.mjs';
import { defaults } from '../bridge/state.mjs';

test('work items use the Boards project, both identities, board types and correct links', async () => {
  const ado = new ADO();
  ado.settings = { ...defaults, organization: 'example', project: 'Code', workItemProject: 'Team Boards',
    team: 'Kanban', workItemTypes: "Activity, Bug, User Story", colleagueEmail: "o'brien@example.com", dueDateField: 'Custom.DueDate' };
  const calls = [];
  ado.call = async (name, args) => {
    calls.push({ name, ...args });
    if (name === 'wit_query') {
      const shared = args.wiql.includes(' OR ');
      return { workItems: (shared ? [1,2] : args.wiql.includes('= @me') ? [1] : [2]).map(id => ({ id })) };
    }
    return args.ids.map(id => ({ id, fields: { 'System.Title': 'Fixture ' + id, 'System.State': 'Active',
      'System.AssignedTo': id === 1 ? 'Me <me@example.com>' : { displayName: 'Colleague' },
      'System.ChangedDate': '2026-10-0' + id + 'T12:00:00Z' } }));
  };
  const items = await ado.workItems();
  assert.ok(calls.every(c => c.project === 'Team Boards'));
  const queries = calls.filter(c => c.name === 'wit_query');
  assert.equal(queries.length, 5);
  assert.ok(queries.every(c => c.team === 'Kanban' && c.timePrecision === true));
  assert.ok(queries.every(c => c.wiql.includes("[System.WorkItemType] IN ('Activity', 'Bug', 'User Story')")));
  assert.ok(queries.some(c => c.wiql.includes("= 'o''brien@example.com'")));
  for (const field of ['System.CreatedDate','System.IterationPath','Custom.DueDate']) {
    assert.ok(queries.find(c => c.wiql.includes('[' + field + ']')).wiql.includes("([System.AssignedTo] = @me OR [System.AssignedTo] = 'o''brien@example.com')"));
  }
  assert.deepEqual(items.map(i => i.id), ['2','1']);
  assert.deepEqual(items.find(i => i.id === '1').buckets, ['mine','today','sprint','due','ours']);
  assert.deepEqual(items.find(i => i.id === '2').buckets, ['today','colleague','sprint','due','ours']);
  assert.equal(items.find(i => i.id === '1').assignedTo, 'Me');
  assert.equal(items[0].assignedTo, 'Colleague');
  assert.equal(items[0].url, 'https://dev.azure.com/example/Team%20Boards/_workitems/edit/2');
  assert.equal(ado.baseURL(), 'https://dev.azure.com/example/Code');
});

test('unset Boards project falls back to repository project and a single authenticated identity', async () => {
  const ado = new ADO(); ado.settings = { ...defaults, project: 'Code' };
  const calls = [];
  ado.call = async (_, args) => { calls.push(args); return { workItems: [] }; };
  assert.deepEqual(await ado.workItems(), []);
  assert.equal(calls.length, 2);
  assert.ok(calls.every(c => c.project === 'Code' && !c.team && c.wiql.includes('= @me') && !c.wiql.includes(' OR ')));
});

test('pipeline union stays newest first without duplicating active runs', async () => {
  const ado = new ADO(); ado.settings = { ...defaults, organization: 'example', project: 'Code' }; ado.repository = { id: 'repo' };
  const old = { id: 1, status: 1, queueTime: '2026-10-01T12:00:00Z' };
  const recent = { id: 2, status: 2, result: 2, queueTime: '2026-10-03T12:00:00Z' };
  ado.call = async (_, args) => args.statusFilter === 1 ? [old] : args.statusFilter === 8 ? [] : [recent, old];
  const items = await ado.pipelines();
  assert.deepEqual(items.map(i => i.id), ['2','1']);
  assert.deepEqual(items.map(i => i.status), ['succeeded','running']);
});
