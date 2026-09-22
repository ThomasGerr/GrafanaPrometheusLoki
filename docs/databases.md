# Monitoring databases

The agent can watch the databases on the host it runs on: PostgreSQL
(including Supabase), MySQL and MariaDB, Redis, MongoDB and Microsoft SQL
Server. You give it a connection URL and it does the rest. Like everything
else, it only connects outbound, so there is nothing to open on a firewall.

Each database is one variable in the agent's environment:

```
DB_APP=postgres://monitor:<password>@app-db:5432/app
DB_CACHE=redis://:<password>@cache:6379
```

Set them in Dokploy's Environment tab, or in the agent's `.env`, and
redeploy. With the helper script it is one flag per database, and it adds
the variable for you:

```bash
sudo agent/install.sh --db app=postgres://monitor:<password>@app-db:5432/app
```

The installer also checks every connection before it finishes:

```
==> checking database connections
  ok      app
  FAILING cache: WRONGPASS invalid username-password pair or user is disabled
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

- **Name.** `DB_APP` names the connection `app`, and `DB_MY_SHOP` names it
  `my-shop`. That name is what dashboards and alerts show. With the
  installer, `--db app=…` does the same; without a name it uses the host.
- **Password characters.** A URL reserves some characters. Percent-encode
  them in the password: `@` → `%40`, `:` → `%3A`, `/` → `%2F`, `#` → `%23`,
  `%` → `%25`, `!` → `%21`.
- **Postgres SSL.** For a database on the same host (`localhost`, or a
  container name without dots) the agent adds `sslmode=disable` unless the URL
  sets it. A remote one keeps the Postgres default, `require`.
- **MongoDB.** The path is the database the user was created in
  (`/admin` below). Replica sets: give each member its own variable on the
  host it runs on. The agent monitors one server, not a cluster, and `mongodb+srv://`
  is not supported.

## Where the database runs

**In a Docker container on this host (the usual case on Dokploy).** Use the
container's name, or its Compose service name, as the host:
`postgres://monitor:pw@shop-db:5432/shop`. The agent must share a Docker
network with it. Databases created from Dokploy's *Databases* page are on
`dokploy-network`. `docker inspect <container>` lists a container's networks.

- **With the installer** this is automatic: it finds the network of each
  database host and joins the agent to it. If it cannot find one, name it:
  `--db-network <network>`.
- **Without it,** set `AGENT_DB_NETWORK` to the network's name, for example
  `AGENT_DB_NETWORK=dokploy-network`, next to the `DB_` variables. One
  network; databases spread over several are what the installer is for.

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

Change or delete the `DB_` variable and redeploy. With the installer:

```bash
sudo agent/install.sh --db app=postgres://monitor:<new>@app-db:5432/app   # new password
sudo agent/install.sh --remove-db app                                     # stop monitoring
```

Upgrading from an installer version that kept URLs in `db-connections/`: the
first run moves them into `DB_` variables and deletes those files. A database
whose name had an underscore (`app_db`) is then called `app-db`, and its
dashboard history continues under the new name.

A variable the agent cannot use (a typo in the scheme, a missing user) is
skipped with an error in the agent's log, `docker logs grafana-prometheus-loki-agent`.
The rest of the agent keeps running.

## How it works

For whoever maintains this repo:

- `agent/databases.alloy` defines one Alloy component per engine. At every
  start, `agent/entrypoint.sh` turns each `DB_` variable into a block in
  `connections.alloy` and a credentials file, in the form that engine's
  exporter expects, inside the container. Alloy reads the files as secrets, so
  credentials never appear in the agent's config, UI or logs. The same script
  run as `entrypoint.sh check` is what the installer validates URLs with.
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
