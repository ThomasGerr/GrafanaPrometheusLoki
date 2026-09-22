# Alert runbook

Every alert rule carries a `runbook` annotation pointing at a heading here.
Each entry says what the alert actually means, what to check first, and what
usually turns out to be the cause.

Severity conventions:

- **critical** — someone is affected right now, or will be within the hour.
  Repeats every 2 hours until it clears.
- **warning** — needs attention this week, not tonight.
- **info** — recorded for context. Goes to you only, never to a client.

---

## Host alerts

### HostDown

No metrics at all from a server for over 10 minutes.

Because collection is push-based, a dead host produces no data rather than a
`up == 0` signal — the rule detects the *absence*. That means the alert covers
three quite different situations:

1. The server is genuinely down or unreachable.
2. The network path to the ingest gateway is broken (DNS, firewall, expired
   ingest password).
3. The agent container stopped.

Check in that order:

```bash
ping <host>                                    # 1
ssh <host> 'docker logs --tail 50 grafana-prometheus-loki-agent'   # 2 and 3
```

A `401` in the agent log means the client's password no longer matches
`INGEST_USERS`. If several hosts from the *same client* went quiet at once,
suspect the credential, not the servers. If hosts from *different* clients went
quiet at once, look at the ingest gateway — see **NoClientDataAtAll**.

### HostExporterFailing

The agent is alive and pushing, but one of its collectors cannot be scraped.
Metrics from that collector are missing while everything else keeps working.

Usually a permissions or mount problem after a host upgrade. Check the agent
log for the collector name, and confirm the volume mounts in
`/opt/grafana-prometheus-loki-agent/docker-compose.yml` still match the host layout.

### HostHighCPU

Over 85% CPU averaged across all cores for 15 minutes.

Not automatically a problem — a build server at 90% is doing its job. It
matters when it is sustained and unexplained. Open the **Containers**
dashboard filtered to that host to see which container is responsible.

### HostHighLoad

Load average is more than twice the core count, normalised so the number means
the same on every machine size.

High load with low CPU means processes are blocked on I/O, not compute. Check
the disk throughput panel on **Host Overview** and look for a database doing
unindexed scans or a backup job running in the foreground.

### HostHighMemory

Over 90% of RAM in use, based on `MemAvailable` — so page cache is already
excluded and this is real pressure.

The next allocation spike will invoke the OOM killer. Find the consumer on the
**Containers** dashboard. If it is a container without a memory limit, set one:
an OOM-killed container restarts, an OOM-killed host does not.

### HostSwapping

More than half of swap in use for 20 minutes. Everything on the host gets
slower, often dramatically. Treat it as **HostHighMemory** that has already
started hurting.

### HostDiskSpaceLow

(and **HostDiskSpaceCritical** — the same alert at 95%)

Over 85% (warning) or 95% (critical) of a filesystem used.

On a Dokploy host the answer is nearly always one of three things:

```bash
docker system df                  # images and build cache
du -sh /var/lib/docker/containers/*/*.log | sort -h | tail   # container logs
du -sh /var/log/* | sort -h | tail
```

`docker system prune -a --volumes` reclaims the first — read what it will
delete before confirming. Unbounded container logs are the second; the
`logging` block in this repo's compose files caps them at 10 MB × 3, and client
stacks should do the same.

### HostDiskWillFillIn24h

Free space is trending to zero within a day, and the filesystem is already over
60% full. This fires well before the usage thresholds and is the one you
actually want to act on — it catches a leak while there is still room to
manoeuvre.

Same investigation as above, but you have time to find the cause instead of
deleting things in a hurry.

### HostInodesLow

Over 90% of inodes used. The filesystem will refuse new files while still
reporting free space, which produces baffling errors.

Millions of small files, almost always in a session directory, a cache, or a
mail spool:

```bash
find / -xdev -type d -exec sh -c 'echo "$(ls -1 "$1" | wc -l) $1"' _ {} \; 2>/dev/null | sort -rn | head
```

### HostRebooted

The host booted less than 10 minutes ago. Informational, and expected after
patching. Investigate only if no maintenance was scheduled — an unexplained
reboot is usually a kernel panic, an OOM event that took the machine down, or
the hosting provider.

### HostClockSkew

The clock is more than 50 ms off.

This breaks TLS handshakes, token validation and log ordering, and it makes
every other metric here unreliable. Check `timedatectl` and whether
`systemd-timesyncd` or `chrony` is running.

---

## Container alerts

### ContainerRestartLoop

More than three restarts in 15 minutes. The container is crashing on startup —
it is not serving traffic and will not recover on its own.

```bash
docker logs --tail 100 <container>
```

Nearly always a missing environment variable, an unreachable database, or a
failed migration in the entrypoint.

### ContainerRestarted

A single restart. Expected during a deploy; this alert exists so that a restart
*without* a deploy is visible. Info-level — you see it, clients do not.

### ContainerOOMKilled

The kernel killed the container for exceeding its memory limit. It will happen
again at the same point in the workload.

Either the limit is too low for legitimate usage, or there is a leak. The
memory panel on the **Containers** dashboard tells you which: a sawtooth that
climbs to the limit and gets cut off is a leak; a flat line near the limit is
an under-provisioned container.

### ContainerHighMemoryVsLimit

Over 90% of the container's configured limit for 15 minutes. This is
**ContainerOOMKilled** with warning ahead of time. Raise the limit or fix the
leak now.

### ContainerHighCPU

Sustained use of most of a core for 20 minutes. Fine for a worker, suspicious
for a web app that should be idle. Compare against the request rate in the
logs — high CPU with no traffic usually means a hot retry loop.

### ContainerDisappeared

A container that was running is no longer present. Either it was removed
deliberately, or it exited and nothing brought it back.

If a deploy just happened and the container was renamed, this is expected noise
and will resolve itself in a couple of hours as the old series age out.

---

## Uptime alerts

### SiteDown

External checks have failed for 3 minutes. Visitors are seeing an error right
now. This is the alert clients feel, and the one worth answering fastest.

Work outward from the application:

```bash
curl -sSv https://<site> 2>&1 | tail -25   # what does the probe see?
ssh <host> docker ps                        # is the container running?
ssh <host> docker logs --tail 50 <container>
```

If the container is healthy but the probe fails, the problem is between the
internet and the host: the reverse proxy, DNS, or the certificate. Check
**SSLCertInvalid** and the Traefik logs on the Dokploy host.

### SiteSlow

Response time over 3 seconds for 15 minutes. Not down, but users notice.

The "Where the time goes" panel on **Uptime & SSL** splits the request into
DNS, connect, TLS handshake and server processing. If it is all in processing,
the problem is the application or its database. If it is in connect or TLS, the
problem is infrastructure.

### HTTPUnexpectedStatus

The endpoint responds but with a 4xx or 5xx. The server is alive, the
application is not well. Check the application logs on the **Logs** dashboard
filtered to that host.

### SSLCertExpiringSoon

(and **SSLCertExpiryImminent** — the same alert at 3 days)

Under 14 days (warning) or 3 days (critical) of certificate lifetime left.

Let's Encrypt renews at 30 days remaining, so 14 days means renewal has
already failed roughly twice. This is not a reminder — it is a report that
automatic renewal is broken. Check the ACME client on that host before the
certificate actually lapses and every visitor gets a full-page security
warning.

Common causes: port 80 closed for the HTTP-01 challenge, a DNS change, or a
rate limit from too many reissues.

### SSLCertInvalid

The certificate chain failed verification. Usually a missing intermediate
certificate — browsers on desktop often paper over this while mobile clients
and API consumers reject it outright, so it can be live for a while before
anyone reports it.

---

## Security alerts

These come from each host's system logs, evaluated by Loki rather than
Prometheus (`config/loki/security.rules.yml`). They only work on hosts whose
agent ships the journal; see **SystemLogsMissing**. The **Security** dashboard
shows the surrounding activity for every one of them.

A security alert is a lead, not a verdict. Most turn out to be a colleague or
a deploy script. The point is that someone checks.

### SSHBruteForce

One address made more than 50 failed SSH login attempts on a host within 10
minutes.

On any server with SSH open to the internet this happens every day, which is
why it is `info`: you get it once a day, the client never does. It only
matters if the server still accepts passwords. Check:

```bash
ssh <host> 'sudo sshd -T | grep -Ei "^(passwordauthentication|permitrootlogin)"'
```

`passwordauthentication no` means guessing cannot succeed, and you can ignore
the noise. If it says `yes`, switch to keys only, or add fail2ban or CrowdSec
to block repeat offenders.

### SSHLoginAfterFailures

An address failed to log in at least 5 times in the past hour, and then
logged in successfully. **Treat this as serious until explained.**

The harmless explanation is a person who mistyped their password or tried the
wrong key a few times. The other one is a guessed password. Find out which:

1. Open the **Security** dashboard for that host and read the *Successful SSH
   logins* panel: which account, from which address, with a password or a
   key.
2. Ask whoever owns that account whether it was them, from that address.
3. If nobody claims it, act as if the host is compromised: lock the account
   (`sudo passwd -l <user>`), check `~/.ssh/authorized_keys` and recent
   account changes, and look at what ran afterwards in *sudo commands*.

### SSHRootLogin

Someone logged in directly as `root` over SSH.

Even when it is legitimate, logging in as root means the logs cannot tell you
*who* it was. The usual fix is to log in with a personal account and use
`sudo`, and to set `PermitRootLogin no` in `/etc/ssh/sshd_config`. If nobody
expected a root login, handle it like **SSHLoginAfterFailures**.

### SudoAuthFailure

Someone on the host tried to use `sudo` and failed: a wrong password, or an
account that is not allowed to use `sudo` at all.

A single wrong password is usually a typo. Worry when the account is not in
the sudoers file (*user NOT in sudoers*), or when it is an account that
should not have a shell at all, such as a web server user. That pattern
suggests someone got in through an application and is trying to escalate.
The *sudo commands* panel shows which account and from which terminal.

### UserAccountCreated

A new user account was created on the host.

Fine if someone just onboarded a colleague or installed a package that adds
a service account. Attackers also add accounts to keep access. If nobody
knows about it, check the account's groups (`id <user>`) and its
`~/.ssh/authorized_keys`, then remove it (`sudo userdel -r <user>`).

### PrivilegedGroupChange

An account was added to `sudo`, `wheel`, `admin`, `root` or `docker`. Each
of these gives full control over the server. `docker` is on the list because
anyone who can start a container can mount the host's disk.

Confirm the change was intended. If it was not, remove the membership
(`sudo gpasswd -d <user> <group>`) and investigate the account like
**UserAccountCreated**.

### SystemLogsMissing

A host sent system logs during the past 6 hours, but none in the last hour,
while the host itself is still up. (If the whole host is down, **HostDown**
fires instead and suppresses this alert.)

Without system logs every other security alert is blind on that host, which
is also exactly what someone covering their tracks would want. Check:

```bash
ssh <host> 'systemctl status systemd-journald; journalctl -n 5'
ssh <host> 'docker logs --tail 50 grafana-prometheus-loki-agent'
```

A journald that was stopped, or a journal that was wiped (`journalctl` shows
almost nothing), deserves suspicion. An agent error about the journal
directory usually means the agent is older than its install script: re-run
the install command to upgrade it.

### CrowdSecDown

The agent cannot reach CrowdSec on a host where it is turned on. Bans that
already exist keep working, because the firewall bouncer holds on to them. New
attacks are neither detected nor blocked until CrowdSec is back.

```bash
docker ps -a --filter name=grafana-prometheus-loki-crowdsec
docker logs --tail 50 grafana-prometheus-loki-crowdsec
```

It usually fails at start: the hub (where it downloads its parsers and
scenarios) was unreachable, `CROWDSEC_BOUNCER_KEY` is not set (its log says
so), or the data volume was removed. A redeploy, or re-running the installer,
recreates it; the installer also reports what fails.

### CrowdSecBouncerNotBlocking

CrowdSec is running and detecting, but the firewall bouncer has not fetched
its decisions for 10 minutes. Whatever CrowdSec bans is **not actually
blocked**, and nothing else would tell you: the dashboard still shows bans.

```bash
docker logs --tail 30 grafana-prometheus-loki-crowdsec-bouncer
```

- `operation not permitted` from nftables: the container lost `NET_ADMIN`, or
  the host kernel has no nftables support. Redeploy the agent.
- `403` or `access forbidden`: the bouncer's key no longer matches what
  CrowdSec has registered. CrowdSec re-registers it at every start, so
  `docker restart grafana-prometheus-loki-crowdsec` fixes it.
- Restarting over and over: CrowdSec's local API is not answering. Look at
  **CrowdSecDown** first.

### CrowdSecNotReadingLogs

CrowdSec is running but has read no log lines from any source for two hours.
An internet-facing host normally sees SSH probes and web scanners around the
clock, so this means CrowdSec has lost its log sources.
`docker exec grafana-prometheus-loki-crowdsec cscli metrics show acquisition` shows
what each source has read. Common causes: `JOURNAL_DIR` points at the wrong
place (the installer detects it again when re-run), or Traefik or nginx was
renamed so the container name no longer contains "traefik" or "nginx".

A host that really is quiet, such as one only reachable over a VPN, can fire
this without anything being wrong. Turn CrowdSec off there with
`--no-crowdsec`; it has nothing to protect against.

---

## Backup alerts

These cover the backups the agent runs with restic when its `backup` profile
is on ([docs/backups.md](backups.md)). Every run logs what it did:
`docker logs grafana-prometheus-loki-backup` on the host.

### BackupFailed

The most recent backup run did not complete. Earlier snapshots are unaffected;
the run's log says which part failed:

- **the repository** (`cannot reach or initialise`): a wrong or rotated
  storage credential, a deleted bucket, or no network to the storage. Test
  with `docker exec grafana-prometheus-loki-backup backup check`.
- **a path** (`the file backup failed`): usually a directory that disappeared
  or cannot be read.
- **a database dump**: also fires **DatabaseDumpFailed**, which names it.
- **the check**: also fires **BackupRepositoryDamaged**.

Fix the cause, then run one by hand to confirm:
`docker exec grafana-prometheus-loki-backup backup`.

### BackupTooOld

No backup of this host has succeeded for longer than `BACKUP_MAX_AGE_HOURS`
(26 by default). Either the runs are failing (**BackupFailed** fires too), or
they are not running at all: the backup container is stopped, or its
schedule never comes round.

```bash
docker ps -a --filter name=grafana-prometheus-loki-backup
docker logs --tail 30 grafana-prometheus-loki-backup     # "scheduled at ..." and each run
```

If this host really is backed up less often (weekly, say), raise
`BACKUP_MAX_AGE_HOURS` to match rather than living with the alert.

### BackupRepositoryDamaged

`restic check` reported errors in the repository itself: missing or corrupt
pack files, or an inconsistent index. Snapshots may not restore. Do not prune
or forget anything until this is understood.

```bash
docker exec grafana-prometheus-loki-backup restic check          # the full report
docker exec grafana-prometheus-loki-backup restic repair index   # for index errors
docker exec grafana-prometheus-loki-backup restic repair snapshots --forget  # for snapshots pointing at lost data
```

A damaged repository usually means the storage lost or changed data behind
restic's back. Take a fresh full backup into a new repository while you
investigate, so this host is protected in the meantime.

### DatabaseDumpFailed

The dump of one database failed in the last run, so there is no new backup of
it. The run's log shows the dump tool's error. The usual causes:

- the backup user cannot read everything: give it the grants from
  [backups.md](backups.md#what-is-backed-up), or set `BACKUP_DB_<NAME>` to a
  user that can.
- the database was unreachable at that moment, or its password changed.
- a new major version of the database that the dump tool does not know yet.

---

## Database alerts

These cover the databases added to an agent with `--db`
([docs/databases.md](databases.md)). `job` in the alert is the engine, `db`
the name the connection was given. The **Databases** dashboard shows the
history behind each one.

### DatabaseDown

The agent on that host cannot connect to the database. It covers three
different situations, in rough order of likelihood:

1. The database is down, or restarting.
2. The monitoring user's password was changed, or the user was dropped.
3. The network path changed: the database container moved to another Docker
   network, or was recreated under a new name.

The agent logs the exporter's exact error, with the password redacted:

```bash
ssh <host> 'docker logs --tail 200 grafana-prometheus-loki-agent 2>&1 | grep database_'
```

`password authentication failed` or `Login failed` is case 2: update its
`DB_<NAME>` variable and redeploy, or re-run the installer with
`--db <name>=<new url>`. `no such host` or `connection refused`
is case 3, or case 1 if the database container is not running
(`docker ps -a`). If the application is healthy while this fires, the problem
is the monitoring connection, not the database.

### DatabaseConnectionsHigh

More than 80% of the connection limit has been in use for 10 minutes. The
usual causes are a connection leak in the application (connections opened and
never returned), a pool size set higher than the database allows, or several
application replicas that each open a full pool.

Postgres shows who holds them:

```sql
SELECT usename, application_name, state, count(*)
FROM pg_stat_activity GROUP BY 1, 2, 3 ORDER BY 4 DESC;
```

MySQL: `SHOW PROCESSLIST;`. Redis: `CLIENT LIST`. Many connections in `idle`
from one application usually means a leak. For Postgres with many small
clients, a pooler such as PgBouncer (built into Supabase as Supavisor) is the
real fix. Raising `max_connections` costs memory for every connection.

### DatabaseConnectionsExhausted

Over 95%: new connections are about to be refused, and the application is
likely already failing some requests. Handle it like
**DatabaseConnectionsHigh**, but now. The quickest relief is restarting the
application instance holding the most connections. For Postgres,
`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle'
AND state_change < now() - interval '10 minutes';` clears long-idle sessions.

### DatabaseReplicationLag

A Postgres or MySQL replica is more than five minutes behind its primary.
Reads from the replica return stale data, and a failover now would lose that
much.

Common causes: a long-running query on the replica holding back replay
(Postgres), a burst of writes on the primary such as a migration or bulk
import, or a replica with slower disks than the primary. If the lag keeps
growing instead of recovering, the replica cannot keep up and needs more
resources or fewer queries.

### DatabaseReplicationBroken

The MySQL replica's IO or SQL thread has stopped. It is not merely behind:
it is not replicating at all. `SHOW REPLICA STATUS\G` shows the error in
`Last_IO_Error` or `Last_SQL_Error`. A duplicate-key error on the SQL thread
means the replica's data has diverged. Skipping the event will get it running
again, but the right fix is to rebuild the replica from a fresh copy.

### DatabaseDeadlocks

More than 5 deadlocks in 15 minutes. Each one is a transaction the database
killed, which the application sees as an error or a retry.

Deadlocks happen when two transactions lock the same rows in opposite order.
The Postgres log (`docker logs <db container> | grep -A5 deadlock`) names both
statements. The fix belongs in the application: touch rows in a consistent
order, or keep transactions shorter. A sudden start right after a deploy
points at that deploy.

### DatabaseLongTransaction

A Postgres transaction has been open for over an hour. While it is open,
vacuum cannot clean up any row it might still need to see, so every table
bloats, and it keeps holding its locks.

```sql
SELECT pid, usename, application_name, state, now() - xact_start AS age, query
FROM pg_stat_activity WHERE xact_start IS NOT NULL ORDER BY age DESC LIMIT 5;
```

`idle in transaction` means an application opened a transaction and forgot
it: a bug, and `pg_terminate_backend(pid)` is safe. `active` for hours is a
huge report or migration. Check with whoever owns it before killing it.
Setting `idle_in_transaction_session_timeout` prevents the forgotten kind.

### RedisMemoryNearLimit

Redis is above 90% of its `maxmemory`. What happens at 100% depends on
`maxmemory-policy`: with `noeviction` (the default) writes start failing,
and with an `allkeys-*` policy keys are silently evicted. That is fine for a
cache, but not for a queue or a session store.

`redis-cli INFO memory` and `redis-cli --bigkeys` show where the memory
went. Keys written without a TTL are the usual cause.

### RedisPersistenceFailing

Redis's last background save to disk failed. By default Redis then refuses
all writes (`stop-writes-on-bgsave-error`), so the application breaks in a
way that looks unrelated. Even without that, a restart would lose everything
written since the last good save.

`redis-cli INFO persistence` and the Redis container's log give the reason.
It is almost always a full disk (see **HostDiskSpaceLow**) or, on a busy
instance, the fork failing for lack of memory.

---

## Monitoring-stack alerts

These go to you only. If one fires, treat every other alert as unreliable
until it is resolved.

### PrometheusRuleEvaluationFailing

Some alert rules are not being evaluated. Alerts you depend on are silently
not firing. Check `/rules` in the Prometheus UI (via SSH tunnel) for the
failing group. Almost always a bad expression introduced in the last change.

### PrometheusConfigReloadFailed

Prometheus is running on its last known-good config — whatever you just
deployed did not take effect. Run `make validate` locally to find the syntax
error, then redeploy.

### AlertmanagerNotificationsFailing

Alerts are firing but the emails are not arriving. Nobody is being told about
anything.

Usually SMTP credentials that expired or got rejected. Check the Alertmanager
container logs for the provider's error, and confirm `SMTP_USER` /
`SMTP_PASSWORD` in the Dokploy environment.

### LokiRequestErrors

Over 5% of Loki requests are failing. Log ingestion or querying is degraded.
Check the Loki container logs, then disk space on the monitoring host — Loki
fails writes long before the host runs out of space entirely.

### PrometheusTSDBCompactionFailing

Compaction is failing, which means retention has stopped working and the data
directory will grow without bound. Nearly always disk pressure on the
monitoring host itself.

### MonitoringServiceDown

Prometheus cannot scrape one of the stack's own services. What stops working
depends on which one:

- **alertmanager**: no alert emails at all. Every other alert is still
  evaluated, but nobody hears about it.
- **loki**: no logs are stored, the Logs and Security dashboards are empty,
  and the security alerts are not evaluated.
- **blackbox-exporter**: no uptime or certificate checks. Expect **SiteDown**
  for every site at once.
- **grafana**: nobody can see a dashboard. Alerting is unaffected.

```bash
docker ps -a --filter name=em-            # on the monitoring host
docker logs --tail 50 em-<service>
```

A service that keeps restarting usually has a config it cannot parse after
the last deploy: its log says which line. Roll back the commit and redeploy,
then fix it with `make validate`, which would have caught it.

### AlertsNotReachingAlertmanager

Prometheus (metric alerts) or Loki (security alerts) is evaluating alerts but
cannot hand them to Alertmanager. The alerts fire and are then lost, with no
email and no record in Alertmanager. That makes this one of the few alerts
that can arrive while everything else stays silent. Treat it as urgent.

Usually Alertmanager is down or restarting (**MonitoringServiceDown** will be
firing too), or it is rejecting what it receives. Check its log:
`docker logs --tail 50 em-alertmanager`. If Alertmanager is up and healthy,
look at the sender's log for the error: `docker logs em-prometheus` or
`docker logs em-loki`, and search for `notify` or `alertmanager`.

### LokiDiscardingLogs

Loki rejected log lines from a tenant over the last 15 minutes. Those lines
are gone for good. The agent does not retry them, and they will not turn up in
a search. The `reason` label says why:

- **rate_limited**, **per_stream_rate_limit** or **stream_limit**: the tenant
  is sending more than the per-tenant limits in `config/loki/loki.yml` allow
  (`ingestion_rate_mb`, `max_global_streams_per_user`). Usually one container
  has started logging in a loop. Find it on the **Logs** dashboard and fix it
  at the source. Raise the limit only if the volume is legitimate.
- **greater_than_max_sample_age**: lines older than a week. The agent drops
  its own backlog before sending, so this points at a host whose clock is
  badly wrong (see **HostClockSkew**).
- **line_too_long**: single lines over 256 KB, usually a dumped payload.

### NoClientDataAtAll

Not one client host is reporting. This is not every client failing
simultaneously — it is the shared path breaking: the ingest gateway is down,
its credentials were wiped, or its DNS record changed.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://ingest.<domain>/healthz
curl -sS -u '<client>:<password>' -X POST https://ingest.<domain>/api/v1/write --data-binary x
```

`200` then `400` means the gateway is healthy and the credential is good — look
further out at DNS or the network. `401` means `INGEST_USERS` no longer
contains that client.
