# Installing the agent

Every monitored server runs the agent: one container that sends host and
container metrics and logs to the central stack, plus, if you want them,
database monitoring and CrowdSec. It only connects outbound, so there is
nothing to open on the server's firewall.

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

Put a value in single quotes when it contains `$`, a space or `#`, for
example `INGEST_PASSWORD='pa$$word'`. Docker Compose would otherwise read
`$` as a variable. The installer quotes for you.

A database running in another container is reachable only on a network the
agent shares with it. Set `AGENT_DB_NETWORK` to that network's name
(`docker inspect <container>` lists them). Databases created on Dokploy's
*Databases* page are on `dokploy-network`. With `install.sh` this is
automatic, and it also handles databases spread over several networks.

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
