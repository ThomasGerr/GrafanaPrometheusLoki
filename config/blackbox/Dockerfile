# Upstream blackbox exporter with the probe modules baked in. See
# config/prometheus/Dockerfile for why the config is baked, not mounted.
FROM prom/blackbox-exporter:v0.28.0
COPY blackbox.yml /etc/blackbox/blackbox.yml
