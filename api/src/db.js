// Storage for the backup control API: schedules, the job queue, run history
// and the snapshots each agent reports. SQLite, because this is a few
// thousand rows on one host and a file is easy to back up.
import Database from 'better-sqlite3';

export function openDatabase(path) {
  const db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.exec(`
    CREATE TABLE IF NOT EXISTS schedules (
      id          TEXT PRIMARY KEY,
      client      TEXT NOT NULL,
      host        TEXT NOT NULL,
      name        TEXT NOT NULL,
      cron        TEXT NOT NULL,
      sources     TEXT NOT NULL,              -- JSON: what to back up
      keep_daily  INTEGER NOT NULL DEFAULT 7,
      keep_weekly INTEGER NOT NULL DEFAULT 4,
      keep_monthly INTEGER NOT NULL DEFAULT 6,
      enabled     INTEGER NOT NULL DEFAULT 1,
      created_at  TEXT NOT NULL,
      updated_at  TEXT NOT NULL,
      UNIQUE (client, host, name)
    );

    -- Work for an agent to pick up: a backup now, or a restore. Agents poll;
    -- nothing reaches into a monitored server from outside.
    CREATE TABLE IF NOT EXISTS jobs (
      id           TEXT PRIMARY KEY,
      client       TEXT NOT NULL,
      host         TEXT NOT NULL,
      type         TEXT NOT NULL,             -- backup | restore
      payload      TEXT NOT NULL,             -- JSON
      state        TEXT NOT NULL,             -- pending | running | done | failed
      created_at   TEXT NOT NULL,
      claimed_at   TEXT,
      finished_at  TEXT,
      message      TEXT
    );
    CREATE INDEX IF NOT EXISTS jobs_pending ON jobs (client, host, state, created_at);

    CREATE TABLE IF NOT EXISTS runs (
      id          TEXT PRIMARY KEY,
      client      TEXT NOT NULL,
      host        TEXT NOT NULL,
      schedule    TEXT,                       -- schedule name, or 'manual'
      started_at  TEXT NOT NULL,
      finished_at TEXT NOT NULL,
      ok          INTEGER NOT NULL,
      summary     TEXT NOT NULL               -- JSON: what it backed up
    );
    CREATE INDEX IF NOT EXISTS runs_recent ON runs (client, host, finished_at);

    -- What is in each host's repository, as the agent last reported it.
    CREATE TABLE IF NOT EXISTS snapshots (
      client      TEXT NOT NULL,
      host        TEXT NOT NULL,
      snapshot_id TEXT NOT NULL,
      time        TEXT NOT NULL,
      tags        TEXT NOT NULL,              -- JSON array
      paths       TEXT NOT NULL,              -- JSON array
      schedule    TEXT,                       -- which schedule made it
      size_bytes  INTEGER,
      reported_at TEXT NOT NULL,
      PRIMARY KEY (client, host, snapshot_id)
    );
    CREATE INDEX IF NOT EXISTS snapshots_time ON snapshots (client, host, time);

    -- Every agent that has asked this API for work, so the dashboard can
    -- offer the hosts you can actually back up rather than a text box.
    CREATE TABLE IF NOT EXISTS hosts (
      client    TEXT NOT NULL,
      host      TEXT NOT NULL,
      first_seen TEXT NOT NULL,
      last_seen TEXT NOT NULL,
      PRIMARY KEY (client, host)
    );

    -- Who asked for what, kept whatever happens to the job itself.
    CREATE TABLE IF NOT EXISTS audit (
      id        INTEGER PRIMARY KEY AUTOINCREMENT,
      at        TEXT NOT NULL,
      actor     TEXT NOT NULL,
      action    TEXT NOT NULL,
      detail    TEXT NOT NULL
    );
  `);

  // Columns added after the first release. A live database was created by an
  // earlier version of the statements above, and CREATE TABLE IF NOT EXISTS
  // leaves it exactly as it was, so each one is added here if missing.
  const columns = (table) => db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);
  if (!columns('snapshots').includes('schedule')) {
    db.exec('ALTER TABLE snapshots ADD COLUMN schedule TEXT');
  }

  return db;
}

export function audit(db, actor, action, detail) {
  db.prepare('INSERT INTO audit (at, actor, action, detail) VALUES (?, ?, ?, ?)')
    .run(new Date().toISOString(), actor, action, JSON.stringify(detail));
}
