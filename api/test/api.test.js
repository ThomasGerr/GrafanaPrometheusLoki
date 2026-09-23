import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from '../src/server.js';

const TOKEN = 'test-admin-token';
const admin = { 'x-api-key': TOKEN };

function app() {
  return build({ dbPath: ':memory:', adminToken: TOKEN });
}
const schedule = {
  client: 'acme', host: 'web-01', name: 'nightly', cron: '0 3 * * *',
  sources: { paths: ['/etc'], volumes: ['app_data'], databases: ['app'] },
};

test('the dashboard side needs the admin token', async () => {
  const a = app();
  for (const headers of [{}, { 'x-api-key': 'wrong' }]) {
    const res = await a.inject({ method: 'GET', url: '/api/schedules', headers });
    assert.equal(res.statusCode, 401);
  }
  assert.equal((await a.inject({ method: 'GET', url: '/api/schedules', headers: admin })).statusCode, 200);
  await a.close();
});

test('a schedule is created, listed, changed and deleted', async () => {
  const a = app();
  const created = await a.inject({ method: 'POST', url: '/api/schedules', headers: admin, payload: schedule });
  assert.equal(created.statusCode, 201);
  const body = created.json();
  assert.equal(body.sources.paths[0], '/etc');
  assert.equal(body.keep.daily, 7);
  // The dashboard shows this line instead of three JSON arrays.
  assert.equal(body.backs_up, '/etc + volume app_data + database app');

  const list = (await a.inject({ method: 'GET', url: '/api/schedules', headers: admin })).json();
  assert.equal(list.length, 1);

  const patched = (await a.inject({ method: 'PATCH', url: `/api/schedules/${body.id}`, headers: admin,
    payload: { cron: '30 4 * * 0', keep: { daily: 14 }, enabled: false } })).json();
  assert.equal(patched.cron, '30 4 * * 0');
  assert.equal(patched.keep.daily, 14);
  assert.equal(patched.enabled, false);

  assert.equal((await a.inject({ method: 'DELETE', url: `/api/schedules/${body.id}`, headers: admin })).statusCode, 200);
  assert.equal((await a.inject({ method: 'GET', url: '/api/schedules', headers: admin })).json().length, 0);
  await a.close();
});

test('a schedule that would back up nothing, or has a bad cron or path, is refused', async () => {
  const a = app();
  const cases = [
    [{ ...schedule, cron: 'every night' }, 'cron'],
    [{ ...schedule, cron: '0 3 * *' }, 'cron'],
    [{ ...schedule, sources: {} }, 'nothing to back up'],
    [{ ...schedule, sources: { paths: ['etc'] } }, 'absolute'],
    [{ ...schedule, sources: { paths: ['/etc/../root'] } }, 'absolute'],
    [{ ...schedule, name: 'Nightly Backup!' }, 'name'],
    [{ ...schedule, client: '' }, 'client'],
  ];
  for (const [payload, expect] of cases) {
    const res = await a.inject({ method: 'POST', url: '/api/schedules', headers: admin, payload });
    assert.equal(res.statusCode, 400, JSON.stringify(payload));
    assert.match(res.json().error, new RegExp(expect));
  }
  await a.close();
});

test('a form can send its lists as plain text', async () => {
  const a = app();
  const res = await a.inject({ method: 'POST', url: '/api/schedules', headers: admin,
    payload: { ...schedule, name: 'typed', sources: { machine: 'false', paths: '/etc, /var/www', databases: 'app' } } });
  assert.equal(res.statusCode, 201);
  assert.deepEqual(res.json().sources.paths, ['/etc', '/var/www']);
  assert.deepEqual(res.json().sources.databases, ['app']);
  assert.equal(res.json().sources.machine, false);

  // An empty include, as an untouched form field sends it, is no include.
  const job = await a.inject({ method: 'POST', url: '/api/jobs', headers: admin,
    payload: { type: 'restore', client: 'acme', host: 'web-01', snapshot_id: 'abc12345', kind: 'files', include: '', switch: 'false' } });
  assert.equal(job.statusCode, 201);
  assert.equal(job.json().payload.include, undefined);
  assert.equal(job.json().payload.switch, false);
  await a.close();
});

test('the whole machine is a valid source on its own', async () => {
  const a = app();
  const res = await a.inject({ method: 'POST', url: '/api/schedules', headers: admin,
    payload: { ...schedule, name: 'machine', sources: { machine: true } } });
  assert.equal(res.statusCode, 201);
  assert.equal(res.json().sources.machine, true);
  await a.close();
});

test('two schedules on one host cannot share a name', async () => {
  const a = app();
  await a.inject({ method: 'POST', url: '/api/schedules', headers: admin, payload: schedule });
  const again = await a.inject({ method: 'POST', url: '/api/schedules', headers: admin, payload: schedule });
  assert.equal(again.statusCode, 409);
  await a.close();
});

test('an agent only sees its own client and host', async () => {
  const a = app();
  await a.inject({ method: 'POST', url: '/api/schedules', headers: admin, payload: schedule });
  await a.inject({ method: 'POST', url: '/api/schedules', headers: admin,
    payload: { ...schedule, client: 'globex', name: 'theirs' } });

  const mine = await a.inject({ method: 'GET', url: '/agent/schedules?host=web-01', headers: { 'x-client-id': 'acme' } });
  assert.equal(mine.json().length, 1);
  assert.equal(mine.json()[0].name, 'nightly');

  const theirs = await a.inject({ method: 'GET', url: '/agent/schedules?host=web-01', headers: { 'x-client-id': 'globex' } });
  assert.equal(theirs.json()[0].name, 'theirs');

  const otherHost = await a.inject({ method: 'GET', url: '/agent/schedules?host=web-02', headers: { 'x-client-id': 'acme' } });
  assert.equal(otherHost.json().length, 0);

  // No client id (so not through the gateway), or a made-up one: nothing.
  assert.equal((await a.inject({ method: 'GET', url: '/agent/schedules?host=web-01' })).statusCode, 401);
  assert.equal((await a.inject({ method: 'GET', url: '/agent/schedules', headers: { 'x-client-id': 'acme' } })).statusCode, 400);
  await a.close();
});

test('a job is claimed once, and only by the host it is for', async () => {
  const a = app();
  const job = (await a.inject({ method: 'POST', url: '/api/jobs', headers: admin,
    payload: { type: 'backup', client: 'acme', host: 'web-01' } })).json();
  assert.equal(job.state, 'pending');

  const other = await a.inject({ method: 'GET', url: '/agent/job?host=web-02', headers: { 'x-client-id': 'acme' } });
  assert.deepEqual(other.json(), {});
  const otherClient = await a.inject({ method: 'GET', url: '/agent/job?host=web-01', headers: { 'x-client-id': 'globex' } });
  assert.deepEqual(otherClient.json(), {});

  const first = await a.inject({ method: 'GET', url: '/agent/job?host=web-01', headers: { 'x-client-id': 'acme' } });
  assert.equal(first.json().id, job.id);
  const second = await a.inject({ method: 'GET', url: '/agent/job?host=web-01', headers: { 'x-client-id': 'acme' } });
  assert.deepEqual(second.json(), {}, 'a claimed job must not be handed out again');

  // Another client cannot finish it.
  assert.equal((await a.inject({ method: 'POST', url: `/agent/job/${job.id}?host=web-01`,
    headers: { 'x-client-id': 'globex' }, payload: { ok: true } })).statusCode, 404);
  const done = await a.inject({ method: 'POST', url: `/agent/job/${job.id}?host=web-01`,
    headers: { 'x-client-id': 'acme' }, payload: { ok: true, message: 'backed up' } });
  assert.equal(done.json().state, 'done');
  await a.close();
});

test('a restore job needs a snapshot and a kind, and a database needs its name', async () => {
  const a = app();
  const base = { type: 'restore', client: 'acme', host: 'web-01' };
  const cases = [
    [{ ...base }, 'snapshot_id'],
    [{ ...base, snapshot_id: 'zzz' }, 'snapshot_id'],
    [{ ...base, snapshot_id: 'abc12345' }, 'kind'],
    [{ ...base, snapshot_id: 'abc12345', kind: 'database' }, 'database is required'],
    [{ ...base, snapshot_id: 'abc12345', kind: 'files', include: '../etc' }, 'absolute'],
  ];
  for (const [payload, expect] of cases) {
    const res = await a.inject({ method: 'POST', url: '/api/jobs', headers: admin, payload });
    assert.equal(res.statusCode, 400, JSON.stringify(payload));
    assert.match(res.json().error, new RegExp(expect));
  }
  const ok = await a.inject({ method: 'POST', url: '/api/jobs', headers: admin,
    payload: { ...base, snapshot_id: 'latest', kind: 'database', database: 'app' } });
  assert.equal(ok.statusCode, 201);
  assert.equal(ok.json().payload.switch, true, 'restores switch over by default');
  await a.close();
});

test('runs and snapshots come back to the dashboard', async () => {
  const a = app();
  const agent = { 'x-client-id': 'acme' };
  await a.inject({ method: 'POST', url: '/agent/runs?host=web-01', headers: agent,
    payload: { schedule: 'nightly', started_at: '2026-09-23T03:00:00Z', finished_at: '2026-09-23T03:04:00Z', ok: true, summary: { added_bytes: 42 } } });
  await a.inject({ method: 'POST', url: '/agent/snapshots?host=web-01', headers: agent,
    payload: { snapshots: [{ id: 'aabbccdd', time: '2026-09-23T03:03:00Z', tags: ['files'], paths: ['/rootfs/etc'], size_bytes: 10 }] } });

  const runs = (await a.inject({ method: 'GET', url: '/api/runs', headers: admin })).json();
  assert.equal(runs.length, 1);
  assert.equal(runs[0].ok, true);
  assert.equal(runs[0].summary.added_bytes, 42);

  const snaps = (await a.inject({ method: 'GET', url: '/api/snapshots', headers: admin })).json();
  assert.equal(snaps[0].snapshot_id, 'aabbccdd');
  assert.deepEqual(snaps[0].tags, ['files']);
  assert.equal(snaps[0].holds, '/etc', 'a file snapshot says which path it holds');
  assert.equal(snaps[0].label, '2026-09-23 03:03 web-01: /etc', 'and reads as one line in a dropdown');

  await a.inject({ method: 'POST', url: '/agent/snapshots?host=web-01', headers: agent,
    payload: { snapshots: [{ id: 'bbccddee', time: '2026-09-23T03:05:00Z', tags: ['db', 'app'], paths: ['/databases/app.pgdump'] }] } });
  const dumps = (await a.inject({ method: 'GET', url: '/api/snapshots', headers: admin })).json();
  assert.equal(dumps[0].holds, 'database app');

  // A client only reports its own: acme's report must not show up under globex.
  const theirs = (await a.inject({ method: 'GET', url: '/api/snapshots?client=globex', headers: admin })).json();
  assert.equal(theirs.length, 0);
  await a.close();
});
