// ─────────────────────────────────────────────────────────────────────────────
// Backup control API
//
// Two sides:
//   /api/…     for the Backups dashboard. Needs ADMIN_TOKEN; clients never
//              get it, so a client can see their backups but not touch them.
//   /agent/…   for the agents. Reached through the ingest gateway, which
//              authenticates them and stamps X-Client-Id from the
//              authenticated username, exactly as it does for logs. An agent
//              can therefore only ever see and finish its own client's work.
//
// Agents poll: nothing here reaches into a monitored server, so servers keep
// accepting no inbound connections.
// ─────────────────────────────────────────────────────────────────────────────
import Fastify from 'fastify';
import { randomUUID } from 'node:crypto';
import { openDatabase, audit } from './db.js';

const PORT = Number(process.env.PORT || 3000);
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || '';
const DB_PATH = process.env.DB_PATH || '/data/backups.db';

export function build({ dbPath = DB_PATH, adminToken = ADMIN_TOKEN, logger = false } = {}) {
  const db = openDatabase(dbPath);
  const app = Fastify({ logger });

  // ── Validation ─────────────────────────────────────────────────────────
  const NAME = /^[a-z0-9][a-z0-9-]{0,40}$/;
  const HOST = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,60}$/;
  const CLIENT = /^[a-z0-9][a-z0-9_-]{0,40}$/;
  const CRON_FIELD = /^[-0-9*,/]+$/;
  const VOLUME = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,60}$/;
  const SNAPSHOT = /^[a-f0-9]{8,64}$|^latest$/;

  const bad = (reply, message) => reply.code(400).send({ error: message });

  function validCron(cron) {
    const fields = String(cron).trim().split(/\s+/);
    return fields.length === 5 && fields.every((f) => CRON_FIELD.test(f));
  }

  // Lists may arrive as a JSON array or as one string with the items separated
  // by commas or newlines, which is what a form in a dashboard can send.
  function asList(value) {
    if (Array.isArray(value)) return value;
    if (typeof value === 'string') {
      return value.split(/[,\n]/).map((x) => x.trim()).filter((x) => x.length);
    }
    return [];
  }

  const asBool = (value) => value === true || value === 'true';

  // What a schedule may back up. "machine" is everything the agent can read;
  // the others are a list each.
  function cleanSources(sources) {
    if (!sources || typeof sources !== 'object') return 'sources is required';
    const out = { machine: asBool(sources.machine), paths: [], volumes: [], databases: [] };
    for (const p of asList(sources.paths)) {
      if (typeof p !== 'string' || !p.startsWith('/') || p.includes('..') || p.includes('\0')) {
        return `path ${JSON.stringify(p)} must be absolute and without ..`;
      }
      out.paths.push(p.replace(/\/+$/, '') || '/');
    }
    for (const v of asList(sources.volumes)) {
      if (!VOLUME.test(v)) return `volume ${JSON.stringify(v)} is not a Docker volume name`;
      out.volumes.push(v);
    }
    for (const d of asList(sources.databases)) {
      if (!NAME.test(d)) return `database ${JSON.stringify(d)} is not a database name`;
      out.databases.push(d);
    }
    if (!out.machine && !out.paths.length && !out.volumes.length && !out.databases.length) {
      return 'nothing to back up: choose the whole machine, or at least one path, volume or database';
    }
    return out;
  }

  // One line saying what a schedule covers, so a dashboard table can show a
  // sentence instead of three JSON arrays.
  function describeSources(s) {
    const parts = [];
    if (s.machine) parts.push('the whole machine');
    if (s.paths?.length) parts.push(s.paths.join(', '));
    if (s.volumes?.length) parts.push(`volume ${s.volumes.join(', ')}`);
    if (s.databases?.length) parts.push(`database ${s.databases.join(', ')}`);
    return parts.join(' + ');
  }

  const rowToSchedule = (r) => {
    const sources = JSON.parse(r.sources);
    return {
      id: r.id, client: r.client, host: r.host, name: r.name, cron: r.cron,
      sources,
      backs_up: describeSources(sources),
      keep: { daily: r.keep_daily, weekly: r.keep_weekly, monthly: r.keep_monthly },
      enabled: !!r.enabled, created_at: r.created_at, updated_at: r.updated_at,
    };
  };

  // ── Who is asking ──────────────────────────────────────────────────────
  app.decorate('adminOnly', async (req, reply) => {
    const given = req.headers['x-api-key'];
    if (!adminToken || given !== adminToken) {
      return reply.code(401).send({ error: 'unauthorized' });
    }
  });

  // The ingest gateway authenticates the agent and sets this header from the
  // authenticated username; an agent cannot choose its own client.
  app.decorate('agentOnly', async (req, reply) => {
    const client = req.headers['x-client-id'];
    const host = req.query?.host;
    if (!client || !CLIENT.test(client)) return reply.code(401).send({ error: 'unauthorized' });
    if (!host || !HOST.test(host)) return reply.code(400).send({ error: 'host is required' });
    const now = new Date().toISOString();
    db.prepare(`INSERT INTO hosts (client, host, first_seen, last_seen) VALUES (?, ?, ?, ?)
                ON CONFLICT (client, host) DO UPDATE SET last_seen = excluded.last_seen`)
      .run(client, host, now, now);
    req.agent = { client, host };
  });

  app.get('/health', async () => ({ ok: true }));

  // ── Dashboard ──────────────────────────────────────────────────────────
  app.get('/api/schedules', { preHandler: [app.adminOnly] }, async (req) => {
    const { client, host } = req.query;
    const rows = db.prepare(`
      SELECT s.*,
             (SELECT MAX(time) FROM snapshots n
               WHERE n.client = s.client AND n.host = s.host AND n.schedule = s.name) AS last_backup_at,
             (SELECT COUNT(*) FROM snapshots n
               WHERE n.client = s.client AND n.host = s.host AND n.schedule = s.name) AS backup_count
      FROM schedules s
      WHERE (@client IS NULL OR s.client = @client) AND (@host IS NULL OR s.host = @host)
      ORDER BY s.client, s.host, s.name
    `).all({ client: client || null, host: host || null });
    return rows.map((r) => ({
      ...rowToSchedule(r),
      last_backup_at: r.last_backup_at,
      backup_count: r.backup_count,
    }));
  });

  app.post('/api/schedules', { preHandler: [app.adminOnly] }, async (req, reply) => {
    const b = req.body || {};
    if (!CLIENT.test(b.client || '')) return bad(reply, 'client is required');
    if (!HOST.test(b.host || '')) return bad(reply, 'host is required');
    if (!NAME.test(b.name || '')) return bad(reply, 'name must be lowercase letters, digits and -');
    if (!validCron(b.cron || '')) return bad(reply, 'cron must be five fields, e.g. 0 3 * * *');
    const sources = cleanSources(b.sources);
    if (typeof sources === 'string') return bad(reply, sources);
    const keep = b.keep || {};
    const now = new Date().toISOString();
    const id = randomUUID();
    try {
      db.prepare(`
        INSERT INTO schedules (id, client, host, name, cron, sources, keep_daily, keep_weekly, keep_monthly, enabled, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(id, b.client, b.host, b.name, String(b.cron).trim(), JSON.stringify(sources),
        Number(keep.daily ?? 7), Number(keep.weekly ?? 4), Number(keep.monthly ?? 6),
        b.enabled === false ? 0 : 1, now, now);
    } catch (e) {
      if (String(e.message).includes('UNIQUE')) {
        return reply.code(409).send({ error: `${b.host} already has a schedule called ${b.name}` });
      }
      throw e;
    }
    audit(db, 'admin', 'schedule.create', { id, client: b.client, host: b.host, name: b.name });
    return reply.code(201).send(rowToSchedule(db.prepare('SELECT * FROM schedules WHERE id = ?').get(id)));
  });

  app.patch('/api/schedules/:id', { preHandler: [app.adminOnly] }, async (req, reply) => {
    const row = db.prepare('SELECT * FROM schedules WHERE id = ?').get(req.params.id);
    if (!row) return reply.code(404).send({ error: 'no such schedule' });
    const b = req.body || {};
    const next = { cron: row.cron, sources: row.sources, enabled: row.enabled,
      keep_daily: row.keep_daily, keep_weekly: row.keep_weekly, keep_monthly: row.keep_monthly };
    if (b.cron !== undefined) {
      if (!validCron(b.cron)) return bad(reply, 'cron must be five fields, e.g. 0 3 * * *');
      next.cron = String(b.cron).trim();
    }
    if (b.sources !== undefined) {
      const sources = cleanSources(b.sources);
      if (typeof sources === 'string') return bad(reply, sources);
      next.sources = JSON.stringify(sources);
    }
    if (b.enabled !== undefined) next.enabled = b.enabled ? 1 : 0;
    if (b.keep) {
      if (b.keep.daily !== undefined) next.keep_daily = Number(b.keep.daily);
      if (b.keep.weekly !== undefined) next.keep_weekly = Number(b.keep.weekly);
      if (b.keep.monthly !== undefined) next.keep_monthly = Number(b.keep.monthly);
    }
    db.prepare(`UPDATE schedules SET cron = ?, sources = ?, enabled = ?, keep_daily = ?, keep_weekly = ?, keep_monthly = ?, updated_at = ? WHERE id = ?`)
      .run(next.cron, next.sources, next.enabled, next.keep_daily, next.keep_weekly, next.keep_monthly, new Date().toISOString(), req.params.id);
    audit(db, 'admin', 'schedule.update', { id: req.params.id, changed: Object.keys(b) });
    return rowToSchedule(db.prepare('SELECT * FROM schedules WHERE id = ?').get(req.params.id));
  });

  app.delete('/api/schedules/:id', { preHandler: [app.adminOnly] }, async (req, reply) => {
    const row = db.prepare('SELECT * FROM schedules WHERE id = ?').get(req.params.id);
    if (!row) return reply.code(404).send({ error: 'no such schedule' });
    db.prepare('DELETE FROM schedules WHERE id = ?').run(req.params.id);
    audit(db, 'admin', 'schedule.delete', { id: req.params.id, host: row.host, name: row.name });
    return { deleted: req.params.id };
  });

  app.get('/api/runs', { preHandler: [app.adminOnly] }, async (req) => {
    const limit = Math.min(Number(req.query.limit || 50), 500);
    return db.prepare(`
      SELECT * FROM runs
      WHERE (@client IS NULL OR client = @client) AND (@host IS NULL OR host = @host)
      ORDER BY finished_at DESC LIMIT @limit
    `).all({ client: req.query.client || null, host: req.query.host || null, limit })
      .map((r) => ({ ...r, ok: !!r.ok, summary: JSON.parse(r.summary) }));
  });

  // Every agent that has ever polled, newest contact first. The dashboard
  // fills its Client and Host pickers from this.
  app.get('/api/hosts', { preHandler: [app.adminOnly] }, async (req) => {
    return db.prepare(`
      SELECT client, host, first_seen, last_seen FROM hosts
      WHERE (@client IS NULL OR client = @client)
      ORDER BY client, host
    `).all({ client: req.query.client || null });
  });

  app.get('/api/snapshots', { preHandler: [app.adminOnly] }, async (req) => {
    const limit = Math.min(Number(req.query.limit || 100), 1000);
    return db.prepare(`
      SELECT * FROM snapshots
      WHERE (@client IS NULL OR client = @client) AND (@host IS NULL OR host = @host)
        AND (@schedule IS NULL OR schedule = @schedule)
      ORDER BY time DESC LIMIT @limit
    `).all({
      client: req.query.client || null,
      host: req.query.host || null,
      schedule: req.query.schedule || null,
      limit,
    })
      .map((r) => {
        const tags = JSON.parse(r.tags);
        const paths = JSON.parse(r.paths);
        // The agent tags each snapshot `db <name>` or `files <schedule>`, and
        // its paths are under /rootfs. Both are turned into one readable line.
        const named = tags.filter((t) => !String(t).startsWith('sched:'));
        const holds = tags.includes('db')
          ? `database ${named.filter((t) => t !== 'db').join(', ')}`
          : paths.map((x) => x.replace(/^\/rootfs/, '')).join(', ') || named.join(', ');
        // What a dropdown shows for this snapshot: when it was taken, from
        // which host, and what is in it.
        const label = `${r.time.slice(0, 16).replace('T', ' ')} ${r.host}: ${holds}`;
        // Everything a restore needs, in one value a dropdown can carry:
        // which host, which snapshot, and what to put back where.
        const kind = tags.includes('db') ? 'database' : 'files';
        const target = kind === 'database' ? named.filter((t) => t !== 'db')[0] || '' : '';
        const choice = [r.client, r.host, r.snapshot_id, kind, target].join('|');
        return { ...r, tags, paths, holds, label, kind, choice };
      });
  });

  app.get('/api/jobs', { preHandler: [app.adminOnly] }, async (req) => {
    const limit = Math.min(Number(req.query.limit || 50), 500);
    return db.prepare('SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?').all(limit)
      .map((r) => ({ ...r, payload: JSON.parse(r.payload) }));
  });

  // Start a backup now, or restore a snapshot. The agent picks it up within
  // its poll interval; a restore puts the data back beside the live copy and
  // then switches over, keeping what was there as <name>_old_<timestamp>.
  app.post('/api/jobs', { preHandler: [app.adminOnly] }, async (req, reply) => {
    const b = req.body || {};
    if (!CLIENT.test(b.client || '')) return bad(reply, 'client is required');
    if (!HOST.test(b.host || '')) return bad(reply, 'host is required');
    let payload;
    if (b.type === 'backup') {
      payload = { schedule: b.schedule || null };
      if (payload.schedule !== null && !NAME.test(payload.schedule)) return bad(reply, 'schedule must be a schedule name');
    } else if (b.type === 'restore') {
      if (!SNAPSHOT.test(b.snapshot_id || '')) return bad(reply, 'snapshot_id is required');
      if (!['files', 'database'].includes(b.kind)) return bad(reply, 'kind must be files or database');
      payload = { snapshot_id: b.snapshot_id, kind: b.kind, switch: b.switch !== false && b.switch !== 'false' };
      if (b.kind === 'database') {
        if (!NAME.test(b.database || '')) return bad(reply, 'database is required for a database restore');
        payload.database = b.database;
      } else {
        // A form sends every field it has; an empty one means "not given".
        if (b.include !== undefined && b.include !== null && b.include !== '') {
          if (typeof b.include !== 'string' || !b.include.startsWith('/') || b.include.includes('..')) {
            return bad(reply, 'include must be an absolute path without ..');
          }
          payload.include = b.include.replace(/\/+$/, '');
        }
      }
    } else {
      return bad(reply, 'type must be backup or restore');
    }
    const id = randomUUID();
    const now = new Date().toISOString();
    db.prepare('INSERT INTO jobs (id, client, host, type, payload, state, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
      .run(id, b.client, b.host, b.type, JSON.stringify(payload), 'pending', now);
    audit(db, 'admin', `job.${b.type}`, { id, client: b.client, host: b.host, ...payload });
    return reply.code(201).send({ id, state: 'pending', type: b.type, payload });
  });

  // ── Agents ─────────────────────────────────────────────────────────────
  app.get('/agent/schedules', { preHandler: [app.agentOnly] }, async (req) => {
    const { client, host } = req.agent;
    return db.prepare('SELECT * FROM schedules WHERE client = ? AND host = ? AND enabled = 1 ORDER BY name')
      .all(client, host).map(rowToSchedule);
  });

  // Claims the oldest pending job for this host, so two polls cannot run the
  // same work twice.
  app.get('/agent/job', { preHandler: [app.agentOnly] }, async (req) => {
    const { client, host } = req.agent;
    const claim = db.transaction(() => {
      const row = db.prepare(`SELECT * FROM jobs WHERE client = ? AND host = ? AND state = 'pending' ORDER BY created_at LIMIT 1`).get(client, host);
      if (!row) return null;
      db.prepare(`UPDATE jobs SET state = 'running', claimed_at = ? WHERE id = ?`).run(new Date().toISOString(), row.id);
      return row;
    });
    const row = claim();
    return row ? { id: row.id, type: row.type, payload: JSON.parse(row.payload) } : {};
  });

  app.post('/agent/job/:id', { preHandler: [app.agentOnly] }, async (req, reply) => {
    const { client, host } = req.agent;
    const row = db.prepare('SELECT * FROM jobs WHERE id = ? AND client = ? AND host = ?').get(req.params.id, client, host);
    if (!row) return reply.code(404).send({ error: 'no such job' });
    const ok = req.body?.ok === true;
    db.prepare(`UPDATE jobs SET state = ?, finished_at = ?, message = ? WHERE id = ?`)
      .run(ok ? 'done' : 'failed', new Date().toISOString(), String(req.body?.message || '').slice(0, 2000), row.id);
    return { id: row.id, state: ok ? 'done' : 'failed' };
  });

  app.post('/agent/runs', { preHandler: [app.agentOnly] }, async (req, reply) => {
    const { client, host } = req.agent;
    const b = req.body || {};
    if (!b.started_at || !b.finished_at) return bad(reply, 'started_at and finished_at are required');
    const id = randomUUID();
    db.prepare('INSERT INTO runs (id, client, host, schedule, started_at, finished_at, ok, summary) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
      .run(id, client, host, String(b.schedule || 'manual').slice(0, 64), b.started_at, b.finished_at,
        b.ok ? 1 : 0, JSON.stringify(b.summary || {}));
    // Keep the history bounded; the metrics keep the long view.
    db.prepare(`DELETE FROM runs WHERE client = ? AND host = ? AND id NOT IN
      (SELECT id FROM runs WHERE client = ? AND host = ? ORDER BY finished_at DESC LIMIT 200)`)
      .run(client, host, client, host);
    return reply.code(201).send({ id });
  });

  // The agent reports what its repository holds; the dashboard lists these
  // and restores from them.
  app.post('/agent/snapshots', { preHandler: [app.agentOnly] }, async (req, reply) => {
    const { client, host } = req.agent;
    const list = Array.isArray(req.body?.snapshots) ? req.body.snapshots : null;
    if (!list) return bad(reply, 'snapshots must be an array');
    const now = new Date().toISOString();
    const replace = db.transaction(() => {
      db.prepare('DELETE FROM snapshots WHERE client = ? AND host = ?').run(client, host);
      const insert = db.prepare('INSERT OR REPLACE INTO snapshots (client, host, snapshot_id, time, tags, paths, schedule, size_bytes, reported_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)');
      for (const s of list.slice(0, 1000)) {
        if (!s?.id || !s?.time) continue;
        const tags = s.tags || [];
        // The agent tags every snapshot `sched:<name>`; older ones have no
        // such tag and simply belong to no schedule.
        const from = tags.find((t) => String(t).startsWith('sched:'));
        insert.run(client, host, String(s.id).slice(0, 64), String(s.time),
          JSON.stringify(tags), JSON.stringify(s.paths || []),
          from ? String(from).slice(6, 70) : null,
          Number.isFinite(s.size_bytes) ? Math.round(s.size_bytes) : null, now);
      }
    });
    replace();
    return reply.code(201).send({ stored: Math.min(list.length, 1000) });
  });

  app.addHook('onClose', async () => db.close());
  return app;
}

// Started directly (not imported by a test).
if (process.argv[1] && process.argv[1].endsWith('server.js')) {
  if (!ADMIN_TOKEN) {
    console.error('backup-api: ADMIN_TOKEN is required, or nothing could be authorised');
    process.exit(1);
  }
  const app = build({ logger: { level: process.env.LOG_LEVEL || 'warn' } });
  app.listen({ port: PORT, host: '0.0.0.0' })
    .then(() => console.error(`backup-api: listening on ${PORT}`))
    .catch((e) => { console.error(e); process.exit(1); });
}
