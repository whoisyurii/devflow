import test from 'node:test';
import assert from 'node:assert/strict';
import { ADO } from '../bridge/ado.mjs';
import { defaults } from '../bridge/state.mjs';

test('work items use the Boards project, only the personal identity, board types and correct links', async () => {
  const ado = new ADO();
  ado.settings = { ...defaults, organization: 'example', project: 'Code', workItemProject: 'Team Boards',
    team: 'Kanban', workItemTypes: "Activity, Bug, User Story", myEmail: "o'brien@example.com", colleagueEmail: "colleague@example.com", dueDateField: 'Custom.DueDate' };
  const calls = [];
  ado.call = async (name, args) => {
    calls.push({ name, ...args });
    if (name === 'wit_query') {
      return { workItems: (args.wiql.includes('[System.CreatedDate]') ? [2] : [1,2]).map(id => ({ id })) };
    }
    return args.ids.map(id => ({ id, fields: { 'System.Title': 'Fixture ' + id, 'System.State': 'Active',
      'System.AssignedTo': id === 1 ? 'Me <me@example.com>' : { displayName: 'Me' },
      'System.ChangedDate': '2026-10-0' + id + 'T12:00:00Z' } }));
  };
  const items = await ado.workItems();
  assert.ok(calls.every(c => c.project === 'Team Boards'));
  const queries = calls.filter(c => c.name === 'wit_query');
  assert.equal(queries.length, 2);
  assert.ok(queries.every(c => !c.team && c.timePrecision === true));
  assert.ok(queries.every(c => c.wiql.includes("[System.WorkItemType] IN ('Activity', 'Bug', 'User Story')")));
  assert.ok(queries.some(c => c.wiql.includes("= 'o''brien@example.com'")));
  assert.ok(queries.every(c => c.wiql.includes("[System.AssignedTo] = 'o''brien@example.com'")));
  assert.ok(queries.every(c => !c.wiql.includes('colleague@example.com') && !c.wiql.includes('@CurrentIteration') && !c.wiql.includes('Custom.DueDate')));
  assert.ok(queries.every(c => c.wiql.includes("[System.State] NOT IN ('Closed', 'Done', 'Removed')")));
  assert.deepEqual(items.map(i => i.id), ['2','1']);
  assert.deepEqual(items.find(i => i.id === '1').buckets, ['mine']);
  assert.deepEqual(items.find(i => i.id === '2').buckets, ['mine','today']);
  assert.equal(items.find(i => i.id === '1').assignedTo, 'Me');
  assert.equal(items[0].assignedTo, 'Me');
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
