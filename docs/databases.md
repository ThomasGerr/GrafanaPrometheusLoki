# Monitoring databases

The agent can watch the databases on the host it runs on: PostgreSQL
(including Supabase), MySQL and MariaDB, Redis, MongoDB and Microsoft SQL
Server. You give it a connection URL and it does the rest. Like everything
else, it only connects outbound, so there is nothing to open on a firewall.

```bash
curl -fsSL https://raw.githubusercontent.com/ThomasGerr/GrafanaPrometheusLoki/main/agent/install.sh \
  | sudo bash -s -- --db app=postgres://monitor:<password>@app-db:5432/app
```

On a host that already runs the agent, that is the whole command: the client,
ingest URL and password are remembered from the first install. On a new host,
add `--db` to the usual install command. Repeat `--db` for several databases.

The installer checks every connection before it finishes:

```
==> checking database connections
  ok      app (postgres)
  FAILING cache (redis): WRONGPASS invalid username-password pair or user is disabled
```

## What you get

- **Alerts** for a database that is unreachable, a connection pool running
  full, replicas falling behind or stopping, deadlocks, forgotten Postgres
  transactions, and Redis near its memory limit or failing to save. Each has
  an entry in the [alert runbook](alert-runbook.md#database-alerts).
- **The Databases dashboard**, in every Org: one row per database with its
  status, connection use, load, cache hit ratio and size, plus history.

Only health metrics leave the host: counters and sizes. No query text, table
contents or credentials are sent.

## Connection URLs

The engine follows from the scheme:

| Engine | URL |
|---|---|
| PostgreSQL, Supabase | `postgres://monitor:pw@host:5432/dbname` |
| MySQL, MariaDB | `mysql://monitor:pw@host:3306` or `mariadb://…` |
| Redis | `redis://:pw@host:6379`, with an ACL user `redis://monitor:pw@host:6379`, TLS `rediss://…` |
| MongoDB | `mongodb://monitor:pw@host:27017/admin` |
| SQL Server | `sqlserver://monitor:pw@host:1433` or `mssql://…` |

- **Name.** `--db app=postgres://…` names the connection `app`. That name is
  what dashboards and alerts show. Without it, the host name is used. Re-using
  a name replaces that connection.
- **Password characters.** A URL reserves some characters. Percent-encode
  them in the password: `@` → `%40`, `:` → `%3A`, `/` → `%2F`, `#` → `%23`,
  `%` → `%25`, `!` → `%21`.
- **Postgres SSL.** For a database on the same host the installer adds
  `sslmode=disable` unless the URL sets it. A remote one keeps the Postgres
  default, `require`.
- **MongoDB.** The path is the database the user was created in
  (`/admin` below). Replica sets: give each member its own `--db` on the host
  it runs on. The agent monitors one server, not a cluster, and `mongodb+srv://`
  is not supported.

## Where the database runs

**In a Docker container on this host (the usual case on Dokploy).** Use the
container's name, or its Compose service name, as the host:
`postgres://monitor:pw@shop-db:5432/shop`. The installer finds the Docker
network the container is on and joins the agent to it (written to
`/opt/grafana-prometheus-loki-agent/docker-compose.override.yml`). Databases created from
Dokploy's *Databases* page are Swarm services on `dokploy-network`, and are
found by their service name in the same way.

If the detection cannot find it, name the network yourself:
`--db-network <network>`. `docker inspect <container>` lists its networks.
A container that is only on Docker's default `bridge` network cannot be
reached by name. Put it on a user-defined network, or publish its port and
use the next option.

**Directly on the host (installed with apt).** Use `localhost`. Inside the
agent's container that becomes `host.docker.internal`, which is the host as
seen from Docker. The database must listen on the Docker bridge address
(usually `172.17.0.1`), not only on `127.0.0.1`. For Postgres that means
`listen_addresses` in `postgresql.conf`, plus a `pg_hba.conf` line allowing
`172.16.0.0/12`. For MySQL it is `bind-address`.

**On another server.** Use its address as usual. Its firewall must allow this
host. Better still, install the agent on that server too, so its host metrics
are covered as well.

## Create a monitoring user

Give the agent its own read-only user rather than the application's or an
admin's credentials. Each of these grants only what the monitoring queries
need.

**PostgreSQL / Supabase**

```sql
CREATE USER monitor WITH PASSWORD '<password>';
GRANT pg_monitor TO monitor;
```

On Supabase, run it in the SQL editor.

**MySQL / MariaDB**

```sql
CREATE USER 'monitor'@'%' IDENTIFIED BY '<password>' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'monitor'@'%';
```

**MongoDB**

```javascript
db.getSiblingDB("admin").createUser({
  user: "monitor", pwd: "<password>",
  roles: [{ role: "clusterMonitor", db: "admin" }, { role: "read", db: "local" }]
})
```

**SQL Server**

```sql
CREATE LOGIN monitor WITH PASSWORD = '<password>';
GRANT VIEW SERVER STATE TO monitor;
GRANT VIEW ANY DEFINITION TO monitor;
```

**Redis** usually has a single password (`requirepass`). Use it as
`redis://:<password>@host:6379`.

## Changing and removing

```bash
# new password: same name, new URL
curl -fsSL …/agent/install.sh | sudo bash -s -- --db app=postgres://monitor:<new>@app-db:5432/app

# stop monitoring it
curl -fsSL …/agent/install.sh | sudo bash -s -- --remove-db app
```

Every run keeps the other connections and restarts the agent.

## How it works

For whoever maintains this repo:

- `agent/databases.alloy` defines one Alloy component per engine. The
  installer writes `connections.alloy` on the host, with one block per
  database. The URLs themselves live in `/opt/grafana-prometheus-loki-agent/db-connections/`
  and are converted into what each exporter expects in `db-secrets/`. Both
  directories are root-only, and Alloy reads the files as secrets, so
  credentials never appear in the agent's config, UI or logs.
- Each engine keeps an allowlist of the metrics that are actually used:
  roughly 15 to 100 series per database, where the exporters produce up to
  4,500. A metric must be on the allowlist before a rule or panel can use it;
  `make validate` fails until it is. Host and container metrics work the same
  way, through `prometheus.relabel "keep"` in `agent/config.alloy`.
- `config/prometheus/rules/database.rules.yml` translates the five engines'
  metrics into one shared set (`database:up`, `database:connections`,
  `database:connections_max`, `database:operations:rate5m`,
  `database:cache_hit_ratio:rate5m`, `database:size_bytes`). The alerts and
  the dashboard are written against those.
- Client isolation is unchanged: the metrics carry the host's `client` label
  like everything else, so they pass through the same label proxy.
