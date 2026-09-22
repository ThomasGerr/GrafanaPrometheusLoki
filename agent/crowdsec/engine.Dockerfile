# CrowdSec's engine, with a start-up wrapper (engine-start.sh) that takes its
# per-host settings from environment variables and keeps a failed
# registration with CrowdSec's central API from stopping it. The Debian
# variant because the journal source runs journalctl, which the Alpine
# images do not have.
FROM crowdsecurity/crowdsec:v1.8.1-debian
COPY engine-start.sh /grafana-prometheus-loki-start.sh
ENTRYPOINT ["/bin/bash", "/grafana-prometheus-loki-start.sh"]
