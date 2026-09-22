# CrowdSec: blocking attackers automatically

The security alerts tell you about SSH brute force and web scanners. They do
not stop anything. [CrowdSec](https://www.crowdsec.net) does: it reads the
same logs, recognises attacks, and the firewall bouncer drops traffic from
the attackers in the server's own firewall.

It is optional and off by default. It runs on the monitored server next to
the agent, and only on servers where you turn it on. In the agent's
environment (Dokploy's Environment tab, or its `.env`):

```
COMPOSE_PROFILES=crowdsec
CROWDSEC_BOUNCER_KEY=<any long random string: openssl rand -hex 32>
CROWDSEC_WHITELIST=203.0.113.7,198.51.100.0/24
```

Redeploy, and it is on. With the helper script, one flag does all of that and
generates the key:

```bash
sudo agent/install.sh --crowdsec --crowdsec-whitelist 203.0.113.7
```

The installer also checks it before it finishes:

```
==> checking CrowdSec
  ok      crowdsec: never blocking 203.0.113.7,198.51.100.4
          (whitelisted automatically, you are connected from: 198.51.100.4)
  ok      firewall bouncer: pulling decisions, blocking in nftables
```

## What it does

- **Detects** attacks in:
  - sshd, from the system journal: brute force, slow brute force, known
    exploits.
  - Traefik and nginx: vulnerability scanners, WordPress and admin-panel
    probing, path traversal, known CVE exploits. It reads containers whose
    name contains `traefik` or `nginx`, and, with
    `CROWDSEC_TRAEFIK_DIR=/etc/dokploy/traefik/dynamic`, Dokploy's Traefik
    access log. The installer sets that for you on a Dokploy host.
- **Blocks** each attacker for four hours in the server's firewall
  (nftables). That covers SSH, the websites and everything else, including
  ports Docker publishes. Repeat offenders are banned again.
- **Shares** what it sees with the CrowdSec network, and in return blocks the
  community blocklist of addresses attacking others. The blocklist arrives
  a few hours after a server starts sharing. If CrowdSec's central API cannot
  be reached, it runs without it (detecting and blocking locally), logs a
  warning, and tries again at the next start.

## Never locking yourself out

Put every address you manage the server from in `CROWDSEC_WHITELIST`, such as
the office, home or a VPN. The installer also adds the address of your
current SSH session by itself. The whitelist covers everything that can
ban: this server's own detection, the community blocklist, the console and
manual bans. It is applied at every start, so removing an address from the
variable really removes it.

If you are locked out anyway, use your hosting provider's console (not SSH)
and run:

```bash
docker exec grafana-prometheus-loki-crowdsec cscli decisions delete --ip <your ip>
```

The block is lifted within 10 seconds. Use `decisions delete`, never
`cscli alerts delete`: removing the alert deletes its bans in a way the
firewall bouncer never hears about, so the block stays until it expires.
If that has happened, `docker restart grafana-prometheus-loki-crowdsec-bouncer`
rebuilds the firewall rules from scratch.

## Seeing what it does

- **The CrowdSec dashboard**, in every Org: protected hosts, what the bans
  stopped (packets and data dropped, the share of all traffic, per reason:
  detected here, community blocklist, manual), who is banned and why, a live
  list of bans, and whether each host is actually blocking. Blocked traffic
  is counted in packets, not requests: one blocked connection attempt is
  usually a packet or a few, as the attacker's system retries.
- **Alerts**: **CrowdSecDown**, **CrowdSecBouncerNotBlocking** (detecting,
  but the firewall is not enforcing, the failure that looks like protection)
  and **CrowdSecNotReadingLogs**. See the
  [runbook](alert-runbook.md#crowdsecdown).
- **On the server**:

  ```bash
  docker exec grafana-prometheus-loki-crowdsec cscli decisions list     # who is banned
  docker exec grafana-prometheus-loki-crowdsec cscli alerts list        # what was detected
  docker exec grafana-prometheus-loki-crowdsec cscli metrics            # what it reads
  ```

## The CrowdSec console (optional)

To manage your servers at [app.crowdsec.net](https://app.crowdsec.net), copy
the enroll key from the console into `CROWDSEC_ENROLL_KEY` (or pass
`--crowdsec-enroll-key <key>` to the installer), redeploy, and accept the
server in the console. It enrolls once per key. A wrong key only produces a
warning in its log; CrowdSec keeps protecting the server without the console.

## Turning it off

With the installer:

```bash
sudo agent/install.sh --no-crowdsec
```

Without it, remove `crowdsec` from `COMPOSE_PROFILES` **and** remove the two
containers: Compose leaves a service whose profile is no longer active
running, so a redeploy alone does not stop it.

```bash
docker rm -f grafana-prometheus-loki-crowdsec grafana-prometheus-loki-crowdsec-bouncer
```

Stopping the bouncer removes its firewall rules. The whitelist, key and
decision history are kept, so turning it back on picks up where it left off.

## Privacy

Sharing sends each detected attacker's IP address, the attack it matched and
a timestamp to CrowdSec. IP addresses are personal data under the GDPR, so
note this in your record of processing activities. The legal basis is usually
legitimate interest: protecting the service. No log lines, request contents
or anything about your legitimate users is sent.

## How it works

For whoever maintains this repo:

- Two services in `agent/docker-compose.yml`, in the Compose profile
  `crowdsec`, so Compose does not even create them (or build their images)
  unless `COMPOSE_PROFILES` contains it.
  - `crowdsec`: the official engine (`crowdsecurity/crowdsec`, Debian variant,
    because the journal source runs `journalctl`) with a start-up wrapper,
    `agent/crowdsec/engine-start.sh`. Its local API is published on the host's
    loopback only, port 8089.
  - `crowdsec-firewall-bouncer`: built from `agent/crowdsec/bouncer.Dockerfile`.
    CrowdSec publishes no image for it, so the Dockerfile installs their
    signed package and keeps just the static binary on a distroless base,
    17 MB. It runs in the host's network with `NET_ADMIN`, and hooks nftables'
    `input` and `forward`. The second is what makes bans hold for
    Docker-published ports, which bypass the host's `input` chain.
- `engine-start.sh`, at every start: writes which logs to read, registers with
  the central API itself (the image's own start script exits when that fails,
  which would leave a host unprotected because *sharing* failed), and once
  the local API is up: registers the bouncer under `CROWDSEC_BOUNCER_KEY`
  (only when that key does not already work), brings the allowlist
  `grafana-prometheus-loki` in line with `CROWDSEC_WHITELIST` as a diff, and enrolls in
  the console once per key. The healthcheck waits for that step, so the
  bouncer only starts once its key is registered.
- The key reaches the engine as `BOUNCER_KEY_firewall`. The image registers
  a bouncer for every variable whose name contains `BOUNCER_KEY`, so passing
  `CROWDSEC_BOUNCER_KEY` itself would register one called "KEY".
- `agent/crowdsec.alloy` collects CrowdSec's metrics and the bouncer's
  dropped-packet counters, with an allowlist like the rest of the agent. The
  bouncer serves those on `host.docker.internal:60601`: it runs in the host's
  network, and that address is the host's Docker bridge (`docker0`),
  reachable from the agent's containers but not a public interface. Where it
  is not a local address (Docker Desktop), the bouncer logs a bind error and
  keeps blocking; only the counts are missing. CrowdSec's own "usage
  metrics" from bouncers are not used: they reach the engine only every 15
  minutes and are not on its Prometheus endpoint. The agent's start-up instantiates it only when
  `COMPOSE_PROFILES` contains `crowdsec`.
- Footprint when on: roughly 100–150 MiB for the engine and 10 MiB for the
  bouncer.
