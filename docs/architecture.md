# Architecture

Why the stack is shaped this way. Read this before changing anything
structural.

## Push, not pull

Prometheus conventionally scrapes its targets. This deployment inverts that:
agents push via `remote_write` through an authenticating gateway.

Pull would mean every client server exposes its exporters to the internet,
each with its own TLS certificate and credentials, and every client firewall
gets a hole punched in it for our IP. That is a lot of surface area and a lot
of coordination with people who do not work for us.

Push costs one thing — Prometheus needs `--web.enable-remote-write-receiver`,
and a dead host produces *no data* rather than `up == 0`. The alert rules
account for that by detecting absence:

```promql
count_over_time(up{job="node"}[6h]) > 0
unless
count_over_time(up{job="node"}[10m]) > 0
```

"Seen in the last six hours, but not in the last ten minutes." The 6h window
bounds how long the alert can keep firing while a host stays down.

## One agent per host

Grafana Alloy has `prometheus.exporter.unix` and
`prometheus.exporter.cadvisor` built in, so a single container replaces what
would otherwise be node_exporter + cAdvisor + a log shipper. One thing to
install, upgrade and debug on a client machine instead of three.

Alloy also buffers to a write-ahead log. A central-stack restart or a short
network outage does not leave a gap in the graphs — samples replay on
reconnect.

> Promtail is end-of-life. Do not reintroduce it.

## Tenant isolation

Three independent mechanisms, because they protect different paths.

### 1. Grafana Orgs — the user boundary

Data source permissions are a **Grafana Enterprise** feature. In OSS, any user
can query any data source in their Org, including through Explore, regardless
of folder or team permissions. Teams and folders organise dashboards; they do
not contain a determined user.

The Org does. A user in Org A cannot address Org B's data sources at all. So
each client gets an Org, and `bootstrap_grafana.py` explicitly removes new
users from the Main Org — Grafana auto-assigns them there, and left in place
they could switch Orgs in the UI and reach the admin data sources that see
every tenant.

Clients are **Viewers**, never Editors. An Editor can rewrite a panel's query.

### 2. prom-label-proxy — the metrics boundary

Each client Org's Prometheus data source points not at Prometheus but at that
client's own `prom-label-proxy`, started with `--label=client
--label-value=<id>`. It injects that matcher into every PromQL query before
forwarding.

A query naming another tenant is **rejected**, not quietly filtered:

```
{"error":"conflicting label matcher: label matcher \"client=\\\"self\\\"\"
 conflicts with injected matcher \"client=\\\"acme\\\"\"", ...}
```

`--enable-label-apis` is required. Without it the `label_values()` calls behind
every dashboard template variable return nothing and each panel silently
empties.

### 3. Loki tenants — the logs boundary

Loki runs with `auth_enabled: true`, so every read and write must carry
`X-Scope-OrgID`. This is storage-level separation, not a query filter.

On **read**, each Org's Loki data source sends its own tenant id. The admin Org
sends the pipe-separated list of all tenants, which Loki accepts for
multi-tenant reads.

On **write**, the ingest gateway sets the header from the *authenticated
basic-auth username*:

```nginx
proxy_set_header X-Scope-OrgID $remote_user;
```

Never from anything the agent sent. An agent holding acme's password can only
ever write to acme, whatever it puts in its own config.

### The gap

Prometheus `remote_write` has no tenant header. The `client` label comes from
the agent's `external_labels`, so an agent could claim to be someone else.

This is acceptable because we install and control the agents. If that ever
changes, replace Prometheus with **Grafana Mimir**, which enforces
`X-Scope-OrgID` on ingest exactly as Loki does. The label proxies, the
dashboards and the alert rules all continue to work unchanged; only the storage
component and the ingest gateway's Prometheus route move.

`make check-tenancy` tests all of the above against the running stack.

## Generated configuration

`clients.yml` is the only file that is hand-edited per client. `make generate`
derives from it:

| Output | Why it must be generated |
|---|---|
| `config/alertmanager/alertmanager.yml.tmpl` | Alertmanager has no include mechanism; the whole route tree and receiver list must be one file |
| `config/prometheus/scrape/blackbox.yml` | Probe targets, grouped by module, each labelled with its client |
| `docker-compose.clients.yml` | One label proxy service per client |
| `config/grafana/provisioning/datasources/admin.yml` | The admin Loki data source's tenant list changes with every client |
| `generated/grafana-orgs.json` | Input for the bootstrap script, which is stdlib-only and so reads JSON rather than YAML |
| `generated/onboarding/<id>.md` | The exact install command for that client |

Generated files are committed. That is deliberate: the deployed state is
whatever is in git, and a diff shows exactly what a client change did.

`make validate` fails if the generated files are stale, so they cannot drift.

## Secrets

No credential is ever written into the repo.

- **SMTP password** — Alertmanager cannot expand environment variables, so
  `render-and-run.sh` renders the committed template at container start. The
  password specifically bypasses that substitution: it is written to a file and
  referenced via `smtp_auth_password_file`, so a password containing slashes or
  ampersands cannot corrupt the config through `sed`.
- **Ingest passwords** — `INGEST_USERS` is read at container start and turned
  into an nginx credentials file that exists only inside the container.
- **Grafana user passwords** — generated by `bootstrap_grafana.py`, printed
  once, never stored.

Everything else lives in the Dokploy Environment tab.

## Networking on Dokploy

`docker-compose.yml` publishes **no ports at all**. Every service sits on the
private `em-monitor` bridge and talks to its neighbours by container name; the
only way in is the Traefik route you configure in the Dokploy interface. That
means Prometheus, Alertmanager, Loki and blackbox are unreachable from the
internet by construction rather than by a loopback binding.

Two consequences:

- `make bootstrap-server` joins `em-monitor` to reach Grafana, because neither
  `localhost` nor a public URL behind Cloudflare works from the host itself.
- `ssh -L` has nothing to forward to, so `make tunnel` starts a temporary
  proxy on the server's loopback instead.

If Traefik does not route to `grafana` or `ingest`, it is the known Dokploy
compose networking gotcha: uncomment the `dokploy-network` block at the bottom
of `docker-compose.yml`, add that network to both services, and label them
`traefik.docker.network=dokploy-network`.

## Retention

30 days of metrics, 14 days of logs, both on local disk. No object storage,
no Thanos, no Mimir.

The 30-day window is what the **Uptime & SSL** dashboard's "Availability (30d)"
panel reads, which is the number you would quote in an SLA conversation.

If you ever owe contractual annual uptime reports, that is the point to add
Mimir with S3 behind it — and, conveniently, the same change that closes the
remote_write tenancy gap above.
