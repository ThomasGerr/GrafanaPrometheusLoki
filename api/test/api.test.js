import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import Database from 'better-sqlite3';
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

test('a database from an earlier version is brought up to date', async () => {
  const file = path.join(os.tmpdir(), `em-backup-api-${Date.now()}.db`);
  // The snapshots table as the first release created it: no schedule column.
  const old = new Database(file);
  old.exec(`CREATE TABLE snapshots (
    client TEXT NOT NULL, host TEXT NOT NULL, snapshot_id TEXT NOT NULL,
    time TEXT NOT NULL, tags TEXT NOT NULL, paths TEXT NOT NULL,
    size_bytes INTEGER, reported_at TEXT NOT NULL,
    PRIMARY KEY (client, host, snapshot_id))`);
  const old2 = old;

  old2.exec(`CREATE TABLE schedules (
    id TEXT PRIMARY KEY, client TEXT NOT NULL, host TEXT NOT NULL, name TEXT NOT NULL,
    cron TEXT NOT NULL, sources TEXT NOT NULL,
    keep_daily INTEGER NOT NULL DEFAULT 7, keep_weekly INTEGER NOT NULL DEFAULT 4,
    keep_monthly INTEGER NOT NULL DEFAULT 6, enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE (client, host, name))`);
  old2.prepare(`INSERT INTO schedules (id, client, host, name, cron, sources, keep_daily, created_at, updated_at)
    VALUES ('x', 'acme', 'web-01', 'nightly', '0 3 * * *', '{"paths":["/etc"]}', 21, 'now', 'now')`).run();
  old2.close();

  const a = build({ dbPath: file, adminToken: TOKEN });
  // The old daily count becomes how many backups to keep.
  assert.equal((await a.inject({ method: 'GET', url: '/api/schedules', headers: admin })).json()[0].keep, 21);
  const reported = await a.inject({ method: 'POST', url: '/agent/snapshots?host=web-01',
    headers: { 'x-client-id': 'acme' },
    payload: { snapshots: [{ id: 'aabbccdd', time: '2026-09-23T03:03:00Z', tags: ['files', 'sched:nightly'], paths: ['/rootfs/etc'] }] } });
  assert.equal(reported.statusCode, 201);
  assert.equal((await a.inject({ method: 'GET', url: '/api/snapshots?schedule=nightly', headers: admin })).json().length, 1);
  await a.close();
  fs.rmSync(file, { force: true });
  for (const extra of ['-wal', '-shm']) fs.rmSync(file + extra, { force: true });
});

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
  assert.equal(body.keep, 7, 'how many to keep, the default');
  // The dashboard shows this line instead of three JSON arrays.
  assert.equal(body.backs_up, '/etc + volume app_data + database app');

  const list = (await a.inject({ method: 'GET', url: '/api/schedules', headers: admin })).json();
  assert.equal(list.length, 1);

  const patched = (await a.inject({ method: 'PATCH', url: `/api/schedules/${body.id}`, headers: admin,
    payload: { cron: '30 4 * * 0', keep: 14, enabled: false } })).json();
  assert.equal(patched.cron, '30 4 * * 0');
  assert.equal(patched.keep, 14);
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

test('the hosts that poll can be offered as choices, and a schedule knows its last backup', async () => {
  const a = app();
  const agent = { 'x-client-id': 'acme' };
  await a.inject({ method: 'POST', url: '/api/schedules', headers: admin, payload: schedule });

  // A host is known once its agent has asked for work.
  assert.deepEqual((await a.inject({ method: 'GET', url: '/api/hosts', headers: admin })).json(), []);
  await a.inject({ method: 'GET', url: '/agent/schedules?host=web-01', headers: agent });
  await a.inject({ method: 'GET', url: '/agent/schedules?host=web-02', headers: agent });
  const hosts = (await a.inject({ method: 'GET', url: '/api/hosts', headers: admin })).json();
  assert.deepEqual(hosts.map((h) => `${h.client}/${h.host}`), ['acme/web-01', 'acme/web-02']);

  // Snapshots say which schedule made them, and the schedule shows its last.
  await a.inject({ method: 'POST', url: '/agent/snapshots?host=web-01', headers: agent,
    payload: { snapshots: [
      { id: 'aaaaaaaa', time: '2026-09-20T03:00:00Z', tags: ['files', 'nightly', 'sched:nightly'], paths: ['/rootfs/etc'] },
      { id: 'bbbbbbbb', time: '2026-09-23T03:00:00Z', tags: ['db', 'app', 'sched:nightly'], paths: ['/databases/app.pgdump'] },
      { id: 'cccccccc', time: '2026-09-23T04:00:00Z', tags: ['files', 'other', 'sched:other'], paths: ['/rootfs/srv'] },
    ] } });

  const listed = (await a.inject({ method: 'GET', url: '/api/schedules', headers: admin })).json()[0];
  assert.equal(listed.last_backup_at, '2026-09-23T03:00:00Z');
  assert.equal(listed.backup_count, 2, 'only its own snapshots count');

  const mine = (await a.inject({ method: 'GET', url: '/api/snapshots?schedule=nightly', headers: admin })).json();
  assert.deepEqual(mine.map((x) => x.snapshot_id), ['bbbbbbbb', 'aaaaaaaa']);
  assert.equal(mine[0].holds, 'database app', 'the schedule tag stays out of what it holds');
  // One value carries everything a restore needs, so a dropdown is enough.
  assert.equal(mine[0].choice, 'acme|web-01|bbbbbbbb|database|app');
  assert.equal(mine[1].choice, 'acme|web-01|aaaaaaaa|files|');
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
