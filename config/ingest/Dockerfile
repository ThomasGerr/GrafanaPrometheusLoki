FROM nginx:1.31-alpine

# htpasswd(1) — used at container start to turn INGEST_USERS into a
# credentials file. apr1 hashing, which nginx implements natively.
RUN apk add --no-cache apache2-utils

COPY nginx.conf /etc/nginx/nginx.conf
COPY build-htpasswd.sh /docker-entrypoint.d/40-build-htpasswd.sh
RUN chmod +x /docker-entrypoint.d/40-build-htpasswd.sh

EXPOSE 8080
