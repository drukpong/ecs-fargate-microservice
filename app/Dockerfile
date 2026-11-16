# syntax=docker/dockerfile:1

ARG NODE_VERSION=20

# ---- base: shared settings ----
FROM node:${NODE_VERSION}-alpine AS base
WORKDIR /app

# ---- deps: production-only node_modules (cached unless the lockfile changes) ----
FROM base AS deps
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev && mkdir -p /app/node_modules

# ---- test: optional target -> `docker build --target test .` ----
FROM base AS test
COPY package.json package-lock.json ./
RUN npm ci
COPY src ./src
RUN npm test

# ---- runtime: small, non-root, no test files or dev dependencies ----
FROM base AS runtime
ARG APP_VERSION=dev
ENV NODE_ENV=production PORT=3000 APP_VERSION=${APP_VERSION}
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src/server.js ./src/server.js
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/health" || exit 1
CMD ["node", "src/server.js"]
