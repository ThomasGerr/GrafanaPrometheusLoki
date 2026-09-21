# GrafanaPrometheusLoki

Central monitoring for your organisation and its clients. One stack, one place to look,
each client seeing only their own systems.

Prometheus for metrics, Loki for logs, Alertmanager for email alerts, Grafana
for dashboards. Deployed as a Docker Compose stack on Dokploy. Each monitored
server runs a single lightweight agent that pushes data outbound — no inbound
ports, nothing to open on a client firewall.

```
CLIENT SERVER (xN)                 CENTRAL STACK (Dokploy)
┌───────────────────┐              ┌──────────────────────────────────────────┐
│ Grafana Alloy     │  HTTPS       │ ingest (nginx)  ← Traefik/Dokploy domain │
│  • host metrics   │  basic auth  │   authenticates, stamps the tenant       │
│  • container      │─────────────▶│      ├──▶ Prometheus  (30d retention)    │
│    metrics        │  outbound    │      └──▶ Loki        (14d retention)    │
│  • docker logs    │  only        │                                          │
│  • system logs    │              │ Alertmanager ──▶ email (you + client)    │
└───────────────────┘              │ Blackbox exporter — probes sites         │
                                   │ prom-label-proxy × N — tenant boundary   │
   CLIENT WEBSITES ◀───────────────│ Grafana — one Org per client             │
        uptime + TLS probes        └──────────────────────────────────────────┘
```

## What it watches

| | |
|---|---|
| **Hosts** | CPU, memory, disk (including "will fill within 24h"), inodes, load, network, clock drift, reboots |
| **Containers** | Per-container CPU and memory, memory-vs-limit, restart loops, OOM kills, containers that vanish |
| **Websites** | Reachability, response time, HTTP status, TLS certificate expiry — probed from outside |
| **Logs** | Container and system logs, searchable, retained 14 days |
| **Itself** | Failed rule evaluations, undelivered alerts, config reload failures, agents that stop reporting |

## Quick start (local)

```bash
cp .env.example .env      # fill in at least the Grafana and ingest values
make up
make bootstrap            # creates Grafana Orgs, logins, data sources, dashboards
```

`make up` runs `docker-compose.dev.yml` — the same stack with ports published
on `127.0.0.1` so you can open it in a browser. The production file publishes
nothing.

Grafana lands on http://localhost:3000. `make help` lists everything else.

## Adding a client

`clients.yml` is the single source of truth. Everything per-client is generated
from it.

```yaml
clients:
  - id: acme                     # metric label, Loki tenant, ingest username
    name: "Acme B.V."
    email: ops@acme.example           # where their alerts go
    grafana_users:
      - login: jan
        email: jan@acme.example
        name: "Jan de Vries"
    probes:
      - url: https://acme.example
      - url: https://app.acme.example/health
        module: http_health
```

Then:

```bash
make generate     # rebuilds routes, probes, label proxies, onboarding notes
make validate     # catches mistakes before they reach production
git commit -am "add acme" && git push      # Dokploy redeploys
make bootstrap    # creates their Org and prints their login once
```

`generated/onboarding/<id>.md` is written for each client with the exact
install command for their servers. Full walkthrough:
[docs/onboarding-a-client.md](docs/onboarding-a-client.md).

## Installing the agent on a server

```bash
curl -fsSL https://raw.githubusercontent.com/ThomasGerr/GrafanaPrometheusLoki/main/agent/install.sh \
  | sudo bash -s -- --client acme --ingest https://ingest.example.com --password '<password>'
```

One container. Re-running upgrades it. Also install it on the monitoring host
itself with `--client self`, so the machine running all this is watched too.

## Deploying on Dokploy

1. New service → **Docker Compose** → point it at this repo, `docker-compose.yml`.
2. **Environment** tab: paste `.env.example` and fill it in. `INGEST_USERS`
   needs one `clientid:password` pair per client — generate with
   `openssl rand -base64 24`.
3. **Domains** tab: route `grafana` (port 3000) and `ingest` (port 8080).
   Suggested: `monitor.example.com` and `ingest.example.com`. Point
   the DNS A records at the server first, or certificate issuance fails.
   Nothing else gets a domain.
4. Deploy, then run `make bootstrap-server` on the host. It reaches Grafana
   over the stack's internal network — the deployed stack publishes no ports,
   and the public URL sits behind Cloudflare, which blocks the script. From
   your own machine, `GRAFANA_URL=https://monitor.example.com make bootstrap`.

`docker-compose.yml` publishes **no ports at all**. Every service sits on the
private `em-monitor` bridge and talks to its neighbours by container name; the
only way in is the Traefik route you configure in the Dokploy interface. That
means Prometheus, Alertmanager, Loki and blackbox are unreachable from the
internet by construction rather than by a loopback binding.

If Traefik does not route to `grafana` or `ingest`, it is the known Dokploy
compose networking gotcha — uncomment the `dokploy-network` block at the bottom
of `docker-compose.yml`, add that network to both services, and label them
`traefik.docker.network=dokploy-network`.

Because nothing is published, `ssh -L` has nothing to forward to. To reach
Prometheus or Alertmanager on the server, start a temporary proxy there:

```bash
make tunnel        # on the server
ssh -L 9090:localhost:9090 -L 9093:localhost:9093 <server>
make untunnel      # when you are done
```

Sizing: a 2 vCPU / 4 GB VPS comfortably handles around 20 monitored hosts at
these retention settings.

## Exporting panels as images

```bash
make render                          # every client, last 7 days
make render C=acme FROM=now-30d      # one client, last 30 days
```

Writes PNGs to `renders/<client>/<date>/`. The panels are listed in
`config/render/panels.json`. The image renderer is a headless Chromium, so it
is not part of the stack: `make render` starts it for the run (1 GB memory
cap, one image at a time) and removes it afterwards. Between runs it costs
nothing, and Grafana's own "Share → Render image" returns an error.

Grafana and the renderer share `RENDERER_TOKEN` from the environment. Grafana
refuses to start without it.

## How clients are kept separate

This is the part worth understanding, because it is what you are promising them.

Grafana **Organizations** are the boundary. Data source permissions are a
Grafana Enterprise feature; in the open-source edition a Viewer can open
Explore and query any data source in their Org. Teams and folder permissions do
not stop that. Orgs do — a user in one Org cannot reach another Org's data
sources at all.

Inside each client Org:

- **Metrics** go through that client's own `prom-label-proxy`, which injects
  `client="<id>"` into every PromQL query server-side. A hand-written query
  naming another tenant is rejected, not silently filtered.
- **Logs** use Loki's native multi-tenancy. The data source sends
  `X-Scope-OrgID: <id>`; Loki will not return another tenant's streams.
- On the write path, the ingest gateway sets `X-Scope-OrgID` from the
  *authenticated username*, so an agent cannot write into someone else's logs
  regardless of what it sends.

Verify it any time:

```bash
make check-tenancy
```

It queries each client's data sources, tries to reach every other tenant by
name and with the filter stripped, and fails loudly if anything leaks.

### One honest caveat

Prometheus `remote_write` has no tenant header. The `client` label is applied
by the agent's own config, so an agent could in principle claim to be a
different client. That is acceptable here because **you install and control
the agents**. If clients ever run their own, swap Prometheus for
[Grafana Mimir](https://grafana.com/oss/mimir/), which enforces `X-Scope-OrgID`
on ingest exactly as Loki does; the rest of the stack is unchanged.

## Layout

```
clients.yml                  source of truth — everything else is derived
docker-compose.yml           the central stack, as Dokploy runs it (no ports)
docker-compose.dev.yml       the same stack for local work (ports on 127.0.0.1)
docker-compose.clients.yml   GENERATED — one label proxy per client
agent/                       what runs on each monitored server
config/
  prometheus/rules/          31 alert rules across host, container, uptime, meta
  alertmanager/              routing template + HTML email templates
  grafana/dashboards/        4 dashboards, used by every Org
  ingest/                    the authenticating gateway
  render/panels.json         which panels `make render` exports
scripts/
  generate.py                clients.yml → all per-client config
  bootstrap_grafana.py       Orgs, logins, data sources, dashboards
  render.py                  panels → PNG, driven by `make render`
  check-tenancy.sh           proves the isolation actually holds
  validate.sh                checks every config file
docs/                        architecture, onboarding, alert runbook
```

Files marked GENERATED are rebuilt by `make generate` and committed. Edit
`clients.yml`, never the generated output.

## Day-to-day

```bash
make help            # every command
make validate        # before every commit
make logs S=loki     # follow one service
make reload          # apply config changes without restarting Prometheus
make routes C=acme   # show where an alert for acme would be delivered
make check-tenancy   # re-prove client isolation
```

When an alert fires, [docs/alert-runbook.md](docs/alert-runbook.md) has an
entry per alert: what it means, what to check, and what usually causes it.
