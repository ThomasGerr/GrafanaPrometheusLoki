# CrowdSec's firewall bouncer: the part that blocks. CrowdSec publishes no
# container image for it, so this builds one from their signed apt package.
# The binary is static, so the image is that one file on a distroless base:
# no shell, no package manager, nothing else to patch in a container that
# holds NET_ADMIN on the host's network.
#
# Built on the monitored host by `docker compose up`, only when CrowdSec is
# enabled (the `crowdsec` profile).
FROM debian:bookworm-slim AS package
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/crowdsec.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/crowdsec.gpg] https://packagecloud.io/crowdsec/crowdsec/any any main" \
      > /etc/apt/sources.list.d/crowdsec.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends crowdsec-firewall-bouncer-nftables

FROM gcr.io/distroless/static-debian12
COPY --from=package /usr/bin/crowdsec-firewall-bouncer /usr/bin/crowdsec-firewall-bouncer
COPY firewall-bouncer.yaml /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
ENTRYPOINT ["/usr/bin/crowdsec-firewall-bouncer", "-c", "/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"]
