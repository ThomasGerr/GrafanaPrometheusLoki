# The backup control API: schedules, jobs and run history for every agent.
# Small on purpose: Fastify and SQLite, no build step.
FROM node:22-alpine
WORKDIR /app
RUN apk add --no-cache tini
COPY package.json package-lock.json ./
# better-sqlite3 ships prebuilt binaries for Alpine; `npm ci` installs exactly
# what the lock file pins, and --omit=dev leaves the test-only packages out.
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY src ./src
# The data directory belongs to the unprivileged user the service runs as;
# a fresh named volume inherits this ownership when it is first mounted.
RUN mkdir -p /data && chown node:node /data /app
USER node
ENV NODE_ENV=production
EXPOSE 3000
ENTRYPOINT ["/sbin/tini", "--", "node", "src/server.js"]
