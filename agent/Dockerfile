# The agent: upstream Alloy with this repo's config baked in, plus the
# start-up script that generates the per-host part (databases, CrowdSec)
# from environment variables. Built by `docker compose up --build`, on the
# host or by Dokploy, so a changed config file rebuilds and recreates it.
FROM grafana/alloy:v1.19.0
COPY config.alloy databases.alloy crowdsec.alloy /etc/alloy/
COPY entrypoint.sh /usr/local/bin/agent-entrypoint
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
