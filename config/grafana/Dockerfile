# Upstream Grafana with provisioning and dashboards baked in. See
# config/prometheus/Dockerfile for why the config is baked, not mounted.
#
# The dashboards live under /etc/grafana, not /var/lib/grafana: that path is
# the grafana-data volume, which hides anything the image puts there once
# the volume exists, so dashboard updates would never show.
FROM grafana/grafana:13.1.4

# The Backups dashboard reads and drives the backup API through these: the
# Infinity data source queries it (server-side, so the API needs no public
# route and its token never reaches a browser) and the forms panel provides
# the inputs and buttons. They are installed here rather than downloaded at
# start-up, and into /opt for the same reason as the dashboards above: the
# usual plugin directory is inside the grafana-data volume.
# Grafana also installs its Drilldown apps on every start; with the plugin
# directory outside the volume that would mean a download on each deploy, so
# the two this stack has a backend for are baked in as well and the
# start-up install is switched off (GF_PLUGINS_PREINSTALL_DISABLED in the
# Compose file). Nothing is fetched when the container starts.
USER root
ENV GF_PATHS_PLUGINS=/opt/grafana/plugins
RUN for p in "yesoreyeram-infinity-datasource 4.0.0" "volkovlabs-form-panel 6.3.5" \
              grafana-lokiexplore-app grafana-metricsdrilldown-app; do \
      # shellcheck disable=SC2086
      grafana cli --pluginsDir "$GF_PATHS_PLUGINS" plugins install $p || exit 1; \
    done \
 && chown -R grafana:root /opt/grafana
USER grafana

COPY provisioning /etc/grafana/provisioning
COPY dashboards /etc/grafana/dashboards
