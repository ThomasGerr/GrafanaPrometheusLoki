# Backups: restic, the dump tools for the databases the agent monitors, and
# a scheduler (busybox crond). The dump tools come from Alpine's packages:
# pg_dump 18 dumps any older Postgres too; the MariaDB client also dumps
# MySQL, given mariadb-connector-c for MySQL 8's caching_sha2_password login.
# Built by `docker compose up --build`, only with the `backup` profile.
FROM restic/restic:0.19.1
RUN apk add --no-cache bash curl jq postgresql18-client mariadb-client mariadb-connector-c mongodb-tools redis
COPY lib/db-url.sh /usr/local/lib/db-url.sh
COPY backup/backup.sh /usr/local/bin/backup
COPY backup/restore.sh /usr/local/bin/backup-restore
COPY backup/poll.sh /usr/local/bin/backup-poll
COPY backup/backup-entrypoint.sh /usr/local/bin/backup-entrypoint
ENTRYPOINT ["/usr/local/bin/backup-entrypoint"]
