# GrafanaPrometheusLoki

Watch your clients' servers and websites from one place. Get an email when
something breaks. Give every client their own dashboards, where they can see
only their own systems.

Built on open-source tools: Prometheus (metrics), Loki (logs), Alertmanager
(email alerts) and Grafana (dashboards). It is made for people who look after
servers for several clients, such as agencies, freelancers and small hosting
providers.

```
CLIENT SERVER (xN)                 CENTRAL STACK (your monitoring server)
┌───────────────────┐              ┌──────────────────────────────────────────┐
│ Grafana Alloy     │  HTTPS       │ ingest (nginx)                           │
│  • host metrics   │  password    │   checks the password, tags the client   │
│  • container      │─────────────▶│      ├──▶ Prometheus  (30 days)          │
│    metrics        │  outbound    │      └──▶ Loki        (14 days)          │
│  • docker logs    │  only        │                                          │
│  • system logs    │              │ Alertmanager ──▶ email (you + client)    │
└───────────────────┘              │ Blackbox exporter — checks websites      │
                                   │ prom-label-proxy × N — keeps data apart  │
   CLIENT WEBSITES ◀───────────────│ Grafana — one Org per client             │
     uptime + certificate checks   └──────────────────────────────────────────┘
```

Each monitored server runs one small agent that *sends* data to you. You never
need to open a port on a client's firewall.

## What it watches

| | |
|---|---|
| **Servers** | CPU, memory, disk (including "will be full within 24h"), load, network, clock drift, reboots |
| **Containers** | CPU and memory per container, restart loops, out-of-memory kills, containers that disappear |
| **Websites** | Whether it is up, how fast it responds, HTTP status, when the TLS certificate expires |
| **Databases** | PostgreSQL/Supabase, MySQL/MariaDB, Redis, MongoDB, SQL Server: whether it is reachable, connection pool use, load, cache hit ratio, size, replication, deadlocks |
| **Logs** | Container and system logs, searchable for 14 days |
| **Security** | SSH brute force, logins after failed attempts, root logins, failed `sudo`, new accounts, users added to admin groups. Optional CrowdSec blocks attackers automatically |
| **Backups** | Optional restic backups of host paths, Docker volumes and a dump of every database: last good backup, failed runs and dumps, repository integrity |
| **Itself** | Broken alert rules, alerts that never reach Alertmanager, emails that failed to send, stack services that stop, logs that Loki drops, agents that stopped reporting |

57 alert rules come included. Each one has an entry in the
[alert runbook](docs/alert-runbook.md) that explains what it means and what to
check.

The security alerts read each server's system logs, and the **Security**
dashboard shows the logins, `sudo` use and account changes behind them. They
detect and warn; they do not block anything.

To block attackers automatically, turn on CrowdSec on a server with
`COMPOSE_PROFILES=crowdsec` in the agent's environment (or `--crowdsec` with
the install script). It bans attackers in that server's
firewall, including ports Docker publishes, and comes with its own dashboard
and alerts. See [docs/crowdsec.md](docs/crowdsec.md).

Backups work the same way: add `backup` to `COMPOSE_PROFILES` and say where to
store them (`RESTIC_REPOSITORY`), and restic backs that server up every night,
including a consistent dump of every monitored database. Every run is
reported, and a failed or missing backup raises an alert. From the Backups
dashboard you add schedules per host — the whole machine, paths, volumes or
databases — start a backup now, and restore a snapshot, which lands beside
the live data and switches over only once it has finished. See
[docs/backups.md](docs/backups.md).

## What you need

- **A server** for the monitoring stack, running [Dokploy](https://dokploy.com),
  with Git and `make` installed. 2 vCPU and 4 GB RAM is enough for about 20
  monitored servers.
- **A domain** with two hostnames pointing at that server, for example
  `monitor.example.com` (Grafana) and `ingest.example.com` (where agents send
  data).
- **An SMTP account** for sending alert emails.
- **On your own computer:** Git, Docker, `make` and Python 3.

Monitored servers only need Docker with the Compose plugin. For the security
alerts they also need systemd (its journal holds the system logs), which
nearly every Linux server has.

> **Not using Dokploy?** Any host that runs Docker Compose will do, but you
> will need to set up your own reverse proxy with HTTPS in front of
> `grafana` (port 3000) and `ingest` (port 8080). The steps below assume
> Dokploy.

## The key idea: `clients.yml`

Every client is described in one file, `clients.yml`. Each client has an
**id**: a short, lowercase name like `acme`. The id is used everywhere: in the
agent's login, in the stored data, and in Grafana. Choose it carefully,
because changing it later cuts the client off from their history.

One client, `self`, is already there. It stands for your own servers,
including the monitoring server itself.

Never edit the other config files by hand. After you change `clients.yml`,
run `make generate` to rebuild them.

## Getting started

### 1. Get the code

Fork this repository and clone your fork. Dokploy deploys straight from it.

The agent installer downloads its files from GitHub. If your fork has a
different owner or name, update that URL in `agent/install.sh` and
`scripts/generate.py`.

### 2. Describe yourself

Open `clients.yml`. Put your own email address and websites on the `self`
entry, then run:

```bash
make generate     # rebuild the config from clients.yml
make validate     # check everything before you deploy
git commit -am "Set up self" && git push
```

### 3. Deploy on Dokploy

1. Create a new service: **Docker Compose**, pointed at your fork, using
   `docker-compose.yml`.
2. **Environment** tab: paste in the contents of `.env.example` and replace
   every value. Every value is required; Grafana will not even start without
   `RENDERER_TOKEN`. Generate passwords and tokens with
   `openssl rand -base64 24`.
3. **Domains** tab: route `monitor.example.com` to service `grafana`, port
   3000, and `ingest.example.com` to service `ingest`, port 8080. Point the
   DNS records at your server *first*, or the HTTPS certificate will fail.
4. Click **Deploy**.

Later changes need nothing more than a push and a redeploy. Each service's
config is built into its image, so new alert rules, dashboards and website
checks restart only the services they belong to.

If the domains do not work, see
[Networking on Dokploy](docs/architecture.md#networking-on-dokploy).

### 4. Set up Grafana

On the monitoring server, clone your fork and run:

```bash
GF_SECURITY_ADMIN_PASSWORD='<your Grafana admin password>' make bootstrap-server
```

This creates the Grafana Orgs, logins, data sources and dashboards. Any new
login passwords are printed **once**, so save them straight away. Then log in
at `https://monitor.example.com` as `admin`.

### 5. Install the agent on the monitoring server

The agent is `agent/docker-compose.yml`, configured by environment variables
alone, so you can deploy it like any compose app: in Dokploy, with compose
path `agent/docker-compose.yml` and these in the Environment tab (use the
`self` password from `INGEST_USERS`):

```
CLIENT_ID=self
HOST_NAME=monitor
INGEST_URL=https://ingest.example.com
INGEST_PASSWORD=<password>
```

Or let the helper script write that for you, find the right settings for the
server and check the result:

```bash
curl -fsSL https://raw.githubusercontent.com/ThomasGerr/GrafanaPrometheusLoki/main/agent/install.sh \
  | sudo bash -s -- --client self --ingest https://ingest.example.com --password '<password>'
```

Within a minute, the **Host Overview** dashboard shows the server. Changing a
variable and redeploying (or running the script again with just the setting
that changes) is how you change anything later. Every variable is listed in
[docs/agent.md](docs/agent.md).

The agent is light: measured on a server running 21 containers, it used about
5% of one CPU core, 180 MiB of memory and 90 MB a day of upload, plus whatever
its logs add. It only sends the metrics the alerts and dashboards use. CrowdSec,
if you turn it on, adds about 110 MiB.

The `NoClientDataAtAll` alert stays on until the agent of your first real
client reports in. That is expected.

## Adding a client

1. Add them to `clients.yml`:

   ```yaml
   clients:
     - id: acme                       # short, lowercase, never changes
       name: "Acme B.V."
       email: ops@acme.example        # where their alerts go
       grafana_users:                 # optional: dashboard logins for them
         - login: jane
           email: jane@acme.example
           name: "Jane Doe"
       probes:                        # optional: websites to check
         - url: https://acme.example
         - url: https://app.acme.example/health
           module: http_health
   ```

2. Rebuild, check and publish:

   ```bash
   make generate
   make validate
   git commit -am "Add acme" && git push      # Dokploy redeploys
   ```

3. Create a password for their agent (`openssl rand -base64 24`) and add it
   to `INGEST_USERS` in Dokploy, so it reads `self:...,acme:<password>`.
   Redeploy.
4. On the monitoring server, `git pull` and run `make bootstrap-server` again.
   It prints their Grafana login once.
5. Run `make check-tenancy` on the monitoring server. It proves the new client
   cannot see anyone else's data.
6. Install the agent on each of their servers, as in step 5 above, with
   `--client acme` and their password.

For more detail, including how to remove a client, see
[docs/onboarding-a-client.md](docs/onboarding-a-client.md).

## Monitoring databases

To watch a database, give the agent on the server where it runs one variable
per database:

```
DB_APP=postgres://monitor:<password>@app-db:5432/app
```

With the helper script that is `--db app=postgres://…`, and it also joins the
agent to the database's Docker network and tests the connection before it
finishes. The password stays on that server. Nothing changes in `clients.yml`. Supported databases, how to
create a read-only monitoring user, and the details:
[docs/databases.md](docs/databases.md).

## Trying it on your own computer

```bash
cp .env.example .env      # fill in the values
make up                   # start the stack
make bootstrap            # set up Grafana
```

Open http://localhost:3000. Without any agents you will only see the stack
watching itself. `make down` stops it again.

## Everyday commands

```bash
make help            # list every command
make validate        # run before every commit
make logs S=loki     # follow the logs of one service
make reload          # local stack: apply config edits to Prometheus and Alertmanager
make routes C=acme   # show who gets an alert for acme
make check-tenancy   # prove clients cannot see each other's data
```

### Reaching Prometheus or Alertmanager on the server

The deployed stack only exposes Grafana and ingest. To open the others for a
while:

```bash
make tunnel                                                  # on the server
ssh -L 9090:localhost:9090 -L 9093:localhost:9093 <server>   # on your computer
make untunnel                                                # on the server, when done
```

While the tunnel is open, Prometheus is at http://localhost:9090 and
Alertmanager at http://localhost:9093.

### Exporting dashboard panels as images

On the monitoring server:

```bash
make render                          # every client, last 7 days
make render C=acme FROM=now-30d      # one client, last 30 days
```

Images are saved in `renders/<client>/<date>/`. To change which panels are
exported, edit `config/render/panels.json`.

## How clients are kept apart

This matters, because it is what you promise your clients.

Every client gets their own **Grafana Organization** (Org). A user in one Org
cannot see anything in another Org. Within each Org:

- **Metrics** pass through a filter (`prom-label-proxy`) that only lets that
  client's data through. A query that asks for another client's data is
  rejected.
- **Logs** are stored per client in Loki, and each Org can only read its own.
- **Incoming data** is tagged with the client that belongs to the agent's
  password, so one client's agent cannot write into another client's logs.

**One limitation:** the client label on *metrics* comes from the agent's own
settings, so an agent could claim to be a different client. That is fine as
long as **you** install and manage the agents. If clients ever run their own,
replace Prometheus with [Grafana Mimir](https://grafana.com/oss/mimir/).
[docs/architecture.md](docs/architecture.md) has the details.

## Repository layout

```
clients.yml                  your clients: edit this, everything else follows
docker-compose.yml           the stack as Dokploy runs it
docker-compose.dev.yml       the same stack for your own computer
docker-compose.clients.yml   generated: one metrics filter per client
agent/                       what runs on each monitored server
api/                         backup control API: schedules, jobs, restores (Fastify + SQLite)
config/                      Prometheus, Alertmanager, Loki, Grafana and ingest settings
  loki/security.rules.yml    the security alerts, copied per client by `make generate`
generated/                   generated: input for the Grafana setup
scripts/                     generator, Grafana setup, checks
docs/                        agent, architecture, onboarding, databases, CrowdSec, backups, alert runbook
```

Generated files are committed to git, but never edit them by hand. Change
`clients.yml` and run `make generate`.

## License

[MIT](LICENSE)
