# Onboarding a client

End to end this takes about ten minutes, most of it waiting for a deploy.

## 1. Describe them in `clients.yml`

```yaml
  - id: acme                     # see "choosing an id" below
    name: "Acme B.V."            # shown as their Grafana Org name
    email: ops@acme.example           # where their alerts go
    grafana_users:
      - login: jan
        email: jan@acme.example
        name: "Jan de Vries"
    probes:
      - url: https://acme.example
      - url: https://www.acme.example
      - url: https://app.acme.example/health
        module: http_health        # body must say ok/healthy/up
      - url: https://admin.acme.example
        module: http_2xx_or_auth   # 401 is a healthy answer here
```

Optional keys:

- `extra_emails:` — a list of additional alert recipients.
- `internal: true` — no Org, no label proxy, alerts to you only. Used for
  your own infrastructure.

### Choosing an id

The `id` is load-bearing. It is simultaneously the `client` label on every
metric, the Loki tenant, the ingest username, and the key the Grafana Org is
matched on. It must match `[a-z0-9][a-z0-9_-]*`.

**Changing it later orphans all of that client's historical data.** Pick
something short and permanent — a company shorthand, not a project name that
might get rebranded.

## 2. Generate and check

```bash
make generate
make validate
```

`generate` rewrites the Alertmanager routes, the blackbox probe targets, the
per-client label proxy service and their copy of the security alert rules.

## 3. Create their ingest credential

```bash
openssl rand -base64 24
```

Append it to `INGEST_USERS` in the Dokploy Environment tab:

```
INGEST_USERS=self:<existing>,acme:<generated>
```

The username **must** equal the `id`. The ingest gateway derives the Loki
tenant from the authenticated username, so a mismatch silently files their logs
under the wrong client — or, more likely, rejects them.

## 4. Deploy

```bash
git add -A && git commit -m "add acme" && git push
```

Redeploy in Dokploy. The new label proxy container starts, and Prometheus,
Alertmanager and Loki restart with the new probe targets, routing and security
rules. Their config is baked into their images, so only the services whose
config changed are restarted.

## 5. Install the agent on their servers

On each host:

```bash
curl -fsSL https://raw.githubusercontent.com/ThomasGerr/GrafanaPrometheusLoki/main/agent/install.sh \
  | sudo bash -s -- \
      --client acme \
      --ingest https://ingest.example.com \
      --password '<the password from step 3>' \
      --host acme-web-01
```

`--host` is optional and defaults to the machine's hostname. Set it when the
hostname is not something you would want to read in an alert email at 2am —
`acme-web-01` beats `ip-172-31-4-9`.

The installer refuses to finish quietly if the credentials are wrong: it starts
the agent, waits, and reports a rejected login rather than leaving you to find
out tomorrow.

If the server runs databases, add a `--db` per database, now or later:
`--db app=postgres://monitor:<password>@app-db:5432/app`. Create a read-only
monitoring user first. [databases.md](databases.md) has the one-liner for
each engine.

Confirm the data arrived. Run this on the monitoring host — the stack
publishes no ports, so the query goes through the container:

```bash
docker exec em-prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=up{client="acme"}' | head -c 300
```

## 6. Create their Grafana Org and logins

On the monitoring host:

```bash
make bootstrap-server
```

That joins the stack's own Docker network and talks to the Grafana container
directly. From the server neither alternative works: no port is published, so
`localhost:3000` is nothing, and the public URL is behind Cloudflare, whose bot
rules answer `urllib` with a 403 (error 1010) before Grafana ever sees it.

From your own machine, against the deployed stack:

```bash
GRAFANA_URL=https://monitor.example.com make bootstrap
```

Locally against `make up`, plain `make bootstrap` is correct.

This creates the Org, adds the Prometheus data source pointed at *their* label
proxy, adds the Loki data source pinned to *their* tenant, imports the four
dashboards, creates each user as a **Viewer**, and removes them from the Main
Org.

Passwords are generated and printed **once**. They are not stored. Send them
over something you consider acceptable for credentials and ask the user to
change theirs on first login.

## 7. Verify the boundary before you hand over the login

```bash
make check-tenancy
```

This queries each client's data sources, tries to reach every other tenant by
name and with the label filter stripped, and does the same for logs. Do not
send anyone a login until this passes.

---

## Removing a client

1. Uninstall the agent on each of their hosts:
   ```bash
   cd /opt/grafana-prometheus-loki-agent && docker compose down -v && rm -rf /opt/grafana-prometheus-loki-agent
   ```
2. Remove their block from `clients.yml`, then `make generate`.
3. Remove their entry from `INGEST_USERS`.
4. Commit, push, redeploy. Their label proxy container disappears.
5. Delete their Org in Grafana (Administration → Organizations). This deletes
   their users' access along with it.

Their historical metrics and logs age out naturally at 30 and 14 days. If you
need them gone immediately, that requires deleting series from Prometheus and
issuing a Loki delete request for the tenant — worth doing deliberately if
their contract requires it.

## Troubleshooting

**The agent runs but nothing appears.**
Check the ingest gateway's access log — it names the authenticated client on
every request:
```bash
docker compose logs ingest | tail -20
```
`401` means the password or username is wrong. No entries at all means the
agent cannot reach the gateway: check DNS and that the Dokploy domain resolves.

**Metrics arrive but the client's dashboards are empty.**
Their data source points at `prom-label-proxy-<id>`. If the id in
`clients.yml` and the `--client` used at install time differ, the data is
stored under one label and queried under another. Compare:
```bash
docker exec em-prometheus wget -qO- \
  http://localhost:9090/api/v1/label/client/values
```

**Logs arrive but the Logs dashboard is empty.**
The Loki data source sends `X-Scope-OrgID`. Re-run `make bootstrap` — the
header lives in `secureJsonData` and is only rewritten by a data source update.

**The client can see other clients' data.**
Stop and run `make check-tenancy`. The most likely cause is a user who was left
in the Main Org; `bootstrap` removes them, but a user created by hand in the
Grafana UI will not have been.
