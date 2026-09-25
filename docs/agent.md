# Installing the agent

Every monitored server runs the agent: one container that sends host,
process and container metrics and logs to the central stack, plus, if you
want them, database monitoring and CrowdSec. It only connects outbound, so
there is nothing to open on the server's firewall.

The agent is `agent/docker-compose.yml`, configured entirely by environment
variables. There are two ways to deploy it, and both give the same result:

- **With Dokploy or plain Docker Compose.** You set the variables yourself,
  and a redeploy applies every change.
- **With `agent/install.sh`**, a helper that writes the same `.env`, detects
  what it can and checks the result.

## With Dokploy

1. New service, **Docker Compose**, pointed at this repository, compose path
   `agent/docker-compose.yml`.
2. **Environment** tab, at least:

   ```
   CLIENT_ID=acme
   HOST_NAME=acme-web-01
   INGEST_URL=https://ingest.example.com
   INGEST_PASSWORD=<the password for acme from INGEST_USERS>
   ```

3. Deploy. Within a minute the server appears on the **Host Overview**
   dashboard.

Changing a variable and redeploying is all a change takes: the agent
regenerates its config at every start, and Compose recreates exactly the
containers whose settings changed. The same works without Dokploy: clone the
repository on the server, put the variables in `agent/.env`, and run
`docker compose up -d --build` in `agent/`.

## With install.sh

On the server, from a checkout of this repository:

```bash
sudo agent/install.sh --client acme --ingest https://ingest.example.com \
  --password '<password>' --host acme-web-01
```

It writes `/opt/grafana-prometheus-loki-agent/.env` and runs Compose there. On top of
that it:

- finds where the host keeps its journal,
- joins the agent to the Docker networks your databases are on,
- whitelists the address you are connected from when you turn on CrowdSec,
- validates database URLs before changing anything,
- checks the ingest password, every database connection and CrowdSec
  before it finishes.

Later runs remember everything, so you pass only what changes:

```bash
sudo agent/install.sh --db app=postgres://monitor:<pw>@app-db:5432/app
sudo agent/install.sh --crowdsec --crowdsec-whitelist 203.0.113.7
```

If the agent was started some other way (by hand with `docker compose`, or as
a Dokploy app), the installer takes over its settings from the running
container and replaces it. Remove the old directory or Dokploy app
afterwards, or it will start again next to the new one.

## Variables

| Variable | |
|---|---|
| `CLIENT_ID` | **Required.** The client's id from `clients.yml`. |
| `HOST_NAME` | **Required.** How the server appears in dashboards and alerts. `acme-web-01` beats `ip-172-31-4-9`. |
| `INGEST_URL` | **Required.** The ingest gateway, e.g. `https://ingest.example.com`. |
| `INGEST_PASSWORD` | **Required.** This client's password from the central `INGEST_USERS`. |
| `JOURNAL_DIR` | Where the host keeps its systemd journal. Default `/var/log/journal`; `/run/log/journal` on hosts that keep it in memory only. |
| `DB_<NAME>` | A database to monitor, as a URL: `DB_APP=postgres://monitor:pw@app-db:5432/app`. One variable per database. See [databases.md](databases.md). |
| `AGENT_DB_NETWORK` | The Docker network those databases are on, when they run in other containers. On Dokploy usually `dokploy-network`. |
| `COMPOSE_PROFILES` | `crowdsec` turns on CrowdSec. See [crowdsec.md](crowdsec.md). |
| `CROWDSEC_BOUNCER_KEY` | Required with CrowdSec: any long random string (`openssl rand -hex 32`). |
| `CROWDSEC_WHITELIST` | Comma-separated IPs and CIDRs CrowdSec must never block. |
| `CROWDSEC_ENROLL_KEY` | Optional: link the server to app.crowdsec.net. |
| `CROWDSEC_TRAEFIK_DIR` | On a Dokploy host, `/etc/dokploy/traefik/dynamic`, so CrowdSec reads Traefik's access log. |
| `CROWDSEC_LAPI_PORT` | Loopback port for CrowdSec's local API. Default `8089`. |
| `COMPOSE_PROFILES` | `backup` turns on backups with restic (with CrowdSec: `crowdsec,backup`). See [backups.md](backups.md). |
| `RESTIC_REPOSITORY`, `RESTIC_PASSWORD` | Required with backups: where they go and the password that encrypts them. Plus the storage's own variables, e.g. `AWS_ACCESS_KEY_ID`. |
| `BACKUP_PATHS`, `BACKUP_DOCKER_VOLUMES` | What to back up besides the databases: host directories, and `true` for every Docker volume. |
| `BACKUP_DB_<NAME>` | The user a database's dump connects as, when its `DB_<NAME>` user may not read the data. |
| `PROCESS_GROUP_<NAME>` | Processes whose command line matches this regular expression are reported as `<name>`. See [Naming processes](#naming-processes). |
| `LOG_FILE_<NAME>` | A host log file or glob to read, for programs that log to files rather than to the journal or a container. See [Logs from files](#logs-from-files). |
| `CONTAINERD_DIR` | Where containerd's socket lives, if not `/run/containerd`. |
| `BACKUP_SCHEDULE`, `BACKUP_KEEP_*`, `BACKUP_MAX_AGE_HOURS` | When and how long to keep; see [backups.md](backups.md#settings). Schedules added from the dashboard take over from `BACKUP_SCHEDULE`. |

Put a value in single quotes when it contains `$`, a space or `#`, for
example `INGEST_PASSWORD='pa$$word'`. Docker Compose would otherwise read
`$` as a variable. The installer quotes for you.

A database running in another container is reachable only on a network the
agent shares with it. Set `AGENT_DB_NETWORK` to that network's name
(`docker inspect <container>` lists them). Databases created on Dokploy's
*Databases* page are on `dokploy-network`. With `install.sh` this is
automatic, and it also handles databases spread over several networks.

## Naming processes

The Host Overview dashboard shows which processes are using a machine. They
are grouped by the name of their program, because that is what the kernel
offers — and it has two limits worth knowing:

- The name stops at 15 characters, so `.postgres-wrapped` shows as
  `.postgres-wrapp`.
- Everything sharing a binary shares a row. Ten pm2-managed apps are all
  `node`, and every Python service is `python3`.

`PROCESS_GROUP_<NAME>` gives a group its own name by matching the command
line instead:

```
PROCESS_GROUP_API=node .*/api/server\.js
PROCESS_GROUP_WORKER=node .*/worker\.js
PROCESS_GROUP_BACKUPS=/usr/local/bin/nightly-backup
```

which reports those processes as `api`, `worker` and `backups`. The patterns
are tried in order and the first one that matches wins; anything left over
still falls back to the name of its program, so adding a group changes only
what it matches. To see what there is to match, on the host:

```bash
ps -eo pid,comm,args --sort=-pcpu | head -30
```

The agent writes these into `/etc/alloy/processes.alloy` at start-up and logs
each one, so `docker logs grafana-prometheus-loki-agent | grep 'reported as'` says what
it made of them.

## Logs from files

Container logs and the systemd journal are collected without being asked
for. A program that writes its own log file is in neither: pm2 writes to
`~/.pm2/logs/`, and anything started from `rc.local` or a shell script
usually writes wherever it was told to. `LOG_FILE_<NAME>` reads those:

```
LOG_FILE_PM2=/home/deploy/.pm2/logs/*.log
LOG_FILE_NGINX=/var/log/nginx/*.log
```

Each line arrives labelled `program="pm2"` — the same label the journal's
entries carry, so they appear in the Logs dashboard's **Program** filter
beside `sshd` and `sudo` — and `filename` with the file's path on the host,
which is what tells one pm2 app from another. The level is read from the
line as usual, so they count towards the error tables too.

Files are re-checked every 30 seconds, so a glob picks up files that appear
later, and reading starts at the end of each file: a log that has been
written to for months is not replayed on the first start.

If nothing arrives from a host at all, check the journal first. `JOURNAL_DIR`
defaults to `/var/log/journal`, and a host whose journald keeps logs only in
memory has nothing there — its logs are in `/run/log/journal`, and the agent
reads an empty directory until it is pointed at them.

## Removing

```bash
docker compose -f /opt/grafana-prometheus-loki-agent/docker-compose.yml down -v
rm -rf /opt/grafana-prometheus-loki-agent
```

Or delete the Dokploy app. If CrowdSec was on, stopping its bouncer removes
its firewall rules.

## What it costs

Measured on a host running 21 containers: about 5% of one core, 180 MiB of
memory and 90 MB a day of upload, plus whatever its logs add. Databases add
almost nothing. CrowdSec, when on, adds about 110 MiB.

Host processes are grouped by program name, which costs seven series per
distinct program — on a host with 40 of them, 280 series. Reading `/proc`
for every process takes about 85 ms against 17 ms for the host's own
metrics, which is why processes are scraped once a minute rather than twice.
Per-process memory is read from `/proc/<pid>/stat`; the far more expensive
`smaps` is switched off, so what you see is resident memory, not the
proportional set size.
