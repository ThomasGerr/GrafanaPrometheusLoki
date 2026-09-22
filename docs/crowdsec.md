# CrowdSec: blocking attackers automatically

The security alerts tell you about SSH brute force and web scanners. They do
not stop anything. [CrowdSec](https://www.crowdsec.net) does: it reads the
same logs, recognises attacks, and the firewall bouncer drops traffic from
the attackers in the server's own firewall.

It is optional and off by default. It runs on the monitored server next to
the agent, and only on servers where you turn it on:

```bash
curl -fsSL https://raw.githubusercontent.com/ThomasGerr/GrafanaPrometheusLoki/main/agent/install.sh \
  | sudo bash -s -- --crowdsec
```

The installer checks it before it finishes:

```
==> checking CrowdSec
  ok      crowdsec: detecting, never blocking: 203.0.113.7
          (whitelisted automatically, you are connected from: 203.0.113.7)
  ok      firewall bouncer: pulling decisions, blocking in nftables
```

## What it does

- **Detects** attacks in:
  - sshd, from the system journal: brute force, slow brute force, known
    exploits.
  - Traefik and nginx: vulnerability scanners, WordPress and admin-panel
    probing, path traversal, known CVE exploits. It reads containers whose
    name contains `traefik` or `nginx`, and Dokploy's Traefik access log.
- **Blocks** each attacker for four hours in the server's firewall
  (nftables). That covers SSH, the websites and everything else, including
  ports Docker publishes. Repeat offenders are banned again.
- **Shares** what it sees with the CrowdSec network, and in return blocks the
  community blocklist of addresses attacking others. The blocklist arrives
  a few hours after a server starts sharing.

## Never locking yourself out

Put the addresses you manage the server from on the whitelist. The installer
adds the address of your current SSH session by itself; add the others,
such as the office or a VPN:

```bash
... | sudo bash -s -- --crowdsec --crowdsec-whitelist 203.0.113.7,198.51.100.0/24
```

The whitelist covers everything that can ban: this server's own detection,
the community blocklist, the console and manual bans. Each run adds to the
existing whitelist. It is kept even while CrowdSec is off.

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

- **The CrowdSec dashboard**, in every Org: protected hosts, who is banned
  and why, a live list of bans, and whether each host is actually blocking.
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
the enroll key from the console and pass it once:

```bash
... | sudo bash -s -- --crowdsec-enroll-key <key>
```

Then accept the server in the console. A wrong key only produces a warning;
CrowdSec keeps protecting the server without the console.

## Turning it off

```bash
... | sudo bash -s -- --no-crowdsec
```

This stops both containers and removes the firewall rules. The whitelist,
key and decision history are kept, so `--crowdsec` later picks up where it
left off.

## Privacy

Sharing sends each detected attacker's IP address, the attack it matched and
a timestamp to CrowdSec. IP addresses are personal data under the GDPR, so
note this in your record of processing activities. The legal basis is usually
legitimate interest: protecting the service. No log lines, request contents
or anything about your legitimate users is sent.

## How it works

For whoever maintains this repo:

- Two services in `agent/docker-compose.yml`, in the Compose profile
  `crowdsec`. `--crowdsec` puts `COMPOSE_PROFILES=crowdsec` in the agent's
  `.env`. Without it, Compose does not even create them.
  - `crowdsec`: the official engine (`crowdsecurity/crowdsec`, Debian variant,
    because the journal source runs `journalctl`). Its local API is published
    on the host's loopback only, port 8089 (or the next free one).
  - `crowdsec-firewall-bouncer`: built on the server from `agent/crowdsec/`.
    CrowdSec publishes no image for it, so the Dockerfile installs their
    signed package and keeps just the static binary on a distroless base,
    17 MB. It runs in the host's network with `NET_ADMIN`, and hooks nftables'
    `input` and `forward`. The second is what makes bans hold for
    Docker-published ports, which bypass the host's `input` chain.
- `install.sh` writes `crowdsec/acquis.yaml` (which logs to read) and keeps
  the allowlist `grafana-prometheus-loki` in CrowdSec's database in line with
  `CROWDSEC_WHITELIST`. It enrolls in the console itself rather than through
  the image's `ENROLL_KEY`, because the image exits on a failed enrollment,
  and one mistyped key would crash-loop CrowdSec.
- `agent/crowdsec.alloy` collects CrowdSec's metrics, with an allowlist like
  the rest of the agent. It is instantiated from `connections.alloy` only
  when CrowdSec is on.
- Footprint when on: roughly 100–150 MiB for the engine and 10 MiB for the
  bouncer.
