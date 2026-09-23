# Backups with restic

The agent can back up the server it runs on with
[restic](https://restic.net): chosen host directories, every Docker volume,
and a dump of every database it monitors. The backups are encrypted and
deduplicated, and stored wherever restic can store them. The monitoring
stack then tells you when the last good backup was, and alerts when a backup
fails or gets too old.

It is optional and off by default, and turned on per server. In the agent's
environment (Dokploy's Environment tab, or its `.env`):

```
COMPOSE_PROFILES=backup                  # with CrowdSec: crowdsec,backup
RESTIC_REPOSITORY=s3:https://fsn1.your-objectstorage.com/acme-backups/web-01
RESTIC_PASSWORD='<a long random password; store it somewhere safe>'
AWS_ACCESS_KEY_ID=<key>
AWS_SECRET_ACCESS_KEY=<secret>
BACKUP_PATHS=/etc,/opt
BACKUP_DOCKER_VOLUMES=true
```

Redeploy, and it runs every night at 03:00 UTC. With the helper script:

```bash
sudo agent/install.sh --backup \
  --backup-repository s3:https://fsn1.your-objectstorage.com/acme-backups/web-01 \
  --backup-env AWS_ACCESS_KEY_ID=<key> --backup-env AWS_SECRET_ACCESS_KEY=<secret> \
  --backup-paths /etc,/opt --backup-volumes
```

The installer checks that the repository can be reached and opened. If you
give no password it generates one and prints it once.

**Store the password somewhere other than the server.** The backups are
encrypted with it. If the server is lost, the copy in its `.env` is lost with
it, and without the password nobody can read the backups, including you.

## What is backed up

- **Host directories:** `BACKUP_PATHS`, comma-separated.
- **Docker volumes:** with `BACKUP_DOCKER_VOLUMES=true`, everything under
  `/var/lib/docker/volumes`: uploads, app data, configs. The agent's own
  write-ahead log is skipped.
- **Databases:** a consistent dump of every database in a `DB_` variable,
  streamed straight into restic, never written to the server's disk. Each is
  its own snapshot, tagged with the database's name:

  | Engine | Dump |
  |---|---|
  | PostgreSQL, Supabase | `pg_dump --format=custom` of the database in the URL |
  | MySQL, MariaDB | `mariadb-dump` of every user database (or the one in the URL), with routines and events. Not the system schema, and so not accounts and grants: recreate those when restoring |
  | MongoDB | `mongodump --archive --gzip` of everything |
  | Redis | its RDB snapshot |
  | SQL Server | no dump. SQL Server's own backup writes on the database server; back up its volume instead |

  The monitoring user from [databases.md](databases.md) may only read
  statistics, not the data. Give the backup a user that may read everything
  with `BACKUP_DB_<NAME>`, which overrides `DB_<NAME>` for the dump:

  ```
  DB_APP=postgres://monitor:pw@app-db:5432/app          # monitoring
  BACKUP_DB_APP=postgres://backup:pw@app-db:5432/app    # dumps
  ```

  PostgreSQL: `CREATE USER backup WITH PASSWORD '…'; GRANT pg_read_all_data TO backup;`
  MySQL: `GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT, PROCESS ON *.* TO 'backup'@'%';`
  MongoDB: a user with the `backup` role. Redis: its password.
  `BACKUP_DATABASES=false` skips the dumps.

A database's live files in a Docker volume are backed up too, but files
copied while a database writes to them may not restore cleanly. The dump is
the backup to trust.

## Where the backups go

Anything restic supports, through `RESTIC_REPOSITORY` and that backend's own
variables:

| Storage | `RESTIC_REPOSITORY` | Also set |
|---|---|---|
| S3-compatible (Hetzner, AWS, Backblaze S3, Wasabi) | `s3:https://<endpoint>/<bucket>/<path>` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Backblaze B2 | `b2:<bucket>:<path>` | `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY` |
| SFTP | `sftp:user@host:/path` | an SSH key (mount it; see restic's docs) |
| restic REST server | `rest:https://user:pass@host:8000/<path>` | |

The repository is created on the first run. Give every server its own path
in a shared bucket. A repository can be shared between servers (each server
only prunes its own snapshots), but separate ones keep a problem in one from
touching the others.

## Settings

| Variable | Default | |
|---|---|---|
| `BACKUP_SCHEDULE` | `0 3 * * *` | When, as a cron line, in UTC |
| `BACKUP_KEEP_DAILY` / `_WEEKLY` / `_MONTHLY` | 7 / 4 / 6 | How many snapshots to keep; older ones are removed |
| `BACKUP_MAX_AGE_HOURS` | 26 | Alert when the last good backup is older than this |
| `BACKUP_CHECK_READ_DATA` | | e.g. `5%`: also read back that share of the data at each check |
| `BACKUP_RUN_ON_START` | `false` | Run once whenever the container starts |

## Seeing it work

- **The Backups dashboard:** how many hosts are backed up, whether the last
  run and the integrity check passed, and the oldest last backup across the
  fleet — then every schedule with when it last ran, how long runs take and
  how much they add.
- **Alerts:** **BackupFailed**, **BackupTooOld**, **BackupRepositoryDamaged**,
  **DatabaseDumpFailed**. See the [runbook](alert-runbook.md#backupfailed).
- **On the server:**

  ```bash
  docker exec grafana-prometheus-loki-backup backup            # run one now
  docker exec grafana-prometheus-loki-backup restic snapshots  # what is in the repository
  docker logs grafana-prometheus-loki-backup                   # what the runs did
  ```

## Schedules and restores from the dashboard

The Backups dashboard has a band of panels only you can see: **Schedules and
their last backup** with an **Add a schedule** form, **Backups** with
**Restore a backup**, and **Recent actions** with **Back up now**. Client
Orgs get the same dashboard without that band.

A schedule says what to back up — the whole machine, directories and files,
Docker volumes, databases, or any mix — and when, as a cron line in UTC.
Each host can have as many as you like. Client and Host are picked from the
agents that ask this API for work, so the list is the hosts that can
actually back up. The host's agent picks a new schedule up within a minute
and runs it from then on, instead of the single `BACKUP_SCHEDULE` in its
environment. If the API is unreachable, the agent keeps the schedules it
already has.

Restoring starts from the table: **click a schedule** — its last backup, or
any other column — and the panels below it show that schedule's backups.
Pick one in **Restore a backup** and press the button. The backup you pick
carries the rest with it, so there is nothing else to fill in: which host it
came from, and whether it holds files or a database.

**Nothing is written over.** The restore lands beside the live data and only
switches once it has finished, keeping what was there:

| | Restored as | What was there becomes |
|---|---|---|
| Files | `<path>` | `<path>_old_<timestamp>` |
| PostgreSQL | database `<name>` | `<name>_old_<timestamp>` |
| MySQL / MariaDB | database `<name>` | `<name>_old_<timestamp>` |
| MongoDB | database `<name>` | `<name>_old_<timestamp>` |
| Redis | staged on the host as an `.rdb` | not switched — Redis only loads a snapshot at start-up |
| SQL Server | refused — restore its volume instead | |

So a restore that fails leaves the live data untouched, and one you regret is
undone by moving the `_old` copy back. Turning **Switch over** off restores
beside the live data and stops there.

Set it up on the monitoring stack by putting a long random value in
`BACKUP_API_TOKEN` in its `.env`. The monitored hosts need nothing extra:
the agent polls the API through the same ingest gateway and credentials it
already pushes metrics with, so a server still accepts no inbound
connections.

## Restoring by hand

The container has restic and every database's client tools, and it is
already configured for the repository. Restoring into the database a dump
came from overwrites what is there, so restore into a fresh database first,
check it, and only then switch.

```bash
# a database: stream the dump from the latest snapshot into a fresh database
docker exec grafana-prometheus-loki-backup sh -c 'restic dump --tag app latest databases/app.pgdump \
  | pg_restore --no-owner -d "postgresql://postgres:pw@new-db:5432/postgres"'

# MySQL:   restic dump --tag shop latest databases/shop.sql | mariadb --host=… --user=…
# MongoDB: restic dump --tag notes latest databases/notes.archive.gz | mongorestore --archive --gzip --uri=…
# Redis:   restic dump --tag cache latest databases/cache.rdb > dump.rdb, then start Redis with it

# files: restore inside the container, then copy out what you need
docker exec grafana-prometheus-loki-backup restic restore latest --tag files \
  --include /rootfs/etc/nginx --target /tmp/restore
docker cp grafana-prometheus-loki-backup:/tmp/restore/rootfs/etc/nginx ./nginx-restored
```

Snapshot paths start with `/rootfs`, because the container sees the host's
filesystem there: `/rootfs/etc` is the host's `/etc`. It sees the host
read-only, which is why files are restored inside the container and copied
out. From any other machine with restic and the password, `restic restore`
works the usual way. Every procedure above was tested: each database by
restoring into a fresh one, files with `restic restore` and `docker cp`.

## Turning it off

With the installer: `sudo agent/install.sh --no-backup`. Without it, remove
`backup` from `COMPOSE_PROFILES` **and** run
`docker rm -f grafana-prometheus-loki-backup`. Compose leaves the container running
otherwise. The repository and its snapshots are not touched, and the agent
stops reporting the old results, so no "backup too old" alert follows.

## How it works

For whoever maintains this repo:

- The `backup` service in `agent/docker-compose.yml`, in the Compose profile
  `backup`: `restic/restic` plus the dump tools from Alpine's packages
  (`agent/backup/Dockerfile`), busybox `crond` for the schedule, and
  `agent/backup/backup.sh` for a run.
- Dumps use `restic backup --stdin-from-command`: restic runs the dump tool
  and fails the snapshot if it exits non-zero, so a broken dump is never kept
  as a good backup. Database URLs are parsed by `agent/lib/db-url.sh`, the
  same code the agent's monitoring uses.
- Each run writes its results to `restic.prom` in the `backup-metrics`
  volume. The agent mounts that volume, and its host collector's textfile
  reader reports the `restic_*` metrics like any other host metric.
  `config/prometheus/rules/backup.rules.yml` alerts on them. When backups are
  off, the agent's start-up deletes the file.
- The container has a fixed hostname: restic clears a lock left by an
  interrupted run (a redeploy mid-backup) only when it comes from the same
  hostname. With Docker's random one, it would block retention and checks
  for 30 minutes.
- MySQL is dumped per user database rather than with `--all-databases`,
  because a fresh MySQL 8 refuses to load the system schema from a dump.
  The backup would fail exactly when it is needed.
- Schedules, restores and history live in the `backup-api` service on the
  monitoring stack: Fastify over SQLite (`api/`), reachable only on the
  stack's own network. `/api/*` needs the `BACKUP_API_TOKEN`; `/agent/*` is
  reached through the ingest gateway, which authenticates the agent and sets
  `X-Client-Id` from the username it logged in with, so an agent can only
  ever see and finish its own host's work.
- `agent/backup/poll.sh` does the polling: it writes the schedules it is
  given to the container's crontab, claims one job at a time, runs it, and
  reports the result and the repository's snapshots back.
- The dashboard reads and drives the API through Grafana's own backend, with
  the Infinity data source (`Backups`, admin Org only) and the Business Forms
  panel. The token sits in that data source, so it never reaches a browser,
  and `scripts/bootstrap_grafana.py` strips those panels from the copy each
  client Org gets.
- Clicking a row in the schedules table sets three hidden dashboard
  variables (`bclient`, `bhost`, `bschedule`) through an ordinary data link;
  the panels below filter on them and say in their titles what is selected.
  A button inside a table cell would not work here: Grafana fires those from
  the browser, which cannot reach the API.
- Each snapshot is tagged `sched:<name>` by the agent, which is how a backup
  is tied to the schedule that made it. The API turns that into the
  schedule's last backup, and into one `choice` value per snapshot that
  carries host, snapshot, kind and database — so a single dropdown is enough
  to start a restore.
- A restore stages first and switches afterwards (`agent/backup/restore.sh`).
  PostgreSQL renames through a different maintenance database than the one
  being restored, because a database cannot be renamed through a connection
  to itself; MySQL has no database rename, so its tables are moved across.
