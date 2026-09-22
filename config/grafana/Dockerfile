# Upstream Grafana with provisioning and dashboards baked in. See
# config/prometheus/Dockerfile for why the config is baked, not mounted.
#
# The dashboards live under /etc/grafana, not /var/lib/grafana: that path is
# the grafana-data volume, which hides anything the image puts there once
# the volume exists, so dashboard updates would never show.
FROM grafana/grafana:13.1.4
COPY provisioning /etc/grafana/provisioning
COPY dashboards /etc/grafana/dashboards
