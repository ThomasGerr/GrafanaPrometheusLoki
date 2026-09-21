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
