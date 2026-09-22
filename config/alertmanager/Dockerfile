# Upstream Alertmanager with the routing template baked in. See
# config/prometheus/Dockerfile for why the config is baked, not mounted.
FROM prom/alertmanager:v0.34.0
COPY alertmanager.yml.tmpl render-and-run.sh /etc/alertmanager/
COPY templates /etc/alertmanager/templates
