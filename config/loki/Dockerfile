# Upstream Loki with its config and the per-tenant security rules baked in.
# See config/prometheus/Dockerfile for why the config is baked, not mounted.
FROM grafana/loki:3.7.6
COPY loki.yml /etc/loki/loki.yml
COPY rules /etc/loki/rules
