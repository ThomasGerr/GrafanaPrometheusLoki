# The production image: upstream Prometheus with this repo's config baked in.
# Dokploy deploys with `up --build`, so a changed rule or scrape file builds a
# new image and recreates the container, while an unchanged one is a cache hit
# and leaves it running. A bind mount would do neither: Compose does not
# restart a container whose definition is unchanged, and Prometheus does not
# reload on its own. docker-compose.dev.yml bind-mounts instead, for
# `make reload` while you edit.
FROM prom/prometheus:v3.13.2
COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY rules /etc/prometheus/rules
COPY scrape /etc/prometheus/scrape
