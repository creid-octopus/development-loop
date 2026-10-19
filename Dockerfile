# ── Build stage (shared by both targets) ─────────────────────
FROM node:24-slim AS build
WORKDIR /app
COPY src/package*.json ./
RUN npm ci --omit=dev
COPY src/ .

# ── Debug target (feature / RC builds) ───────────────────────
# Full node:24-slim — has shell, curl, npm for exec/debugging
FROM node:24-slim AS debug
WORKDIR /app
COPY --from=build /app .

# ARGs must be re-declared per stage — they don't cross FROM boundaries.
# Defaults make local `docker build` work without any --build-arg flags.
ARG APP_VERSION=0.0.0-local
ARG APP_BRANCH=unknown
ARG APP_BUILD=local
ARG APP_BUILT_AT=unknown
ARG APP_COMMIT_SHA=unknown

# Promote to ENV so server.js can read them via process.env at runtime.
ENV APP_VERSION=${APP_VERSION} \
    APP_BRANCH=${APP_BRANCH} \
    APP_BUILD=${APP_BUILD} \
    APP_BUILT_AT=${APP_BUILT_AT} \
    APP_COMMIT_SHA=${APP_COMMIT_SHA}

EXPOSE 3000
CMD ["node", "server.js"]

# ── Release target (main / stable builds) ────────────────────
# Distroless — no shell, no package manager, minimal attack surface
FROM gcr.io/distroless/nodejs24-debian12 AS release
WORKDIR /app
COPY --from=build /app .

ARG APP_VERSION=0.0.0-local
ARG APP_BRANCH=unknown
ARG APP_BUILD=local
ARG APP_BUILT_AT=unknown
ARG APP_COMMIT_SHA=unknown

ENV APP_VERSION=${APP_VERSION} \
    APP_BRANCH=${APP_BRANCH} \
    APP_BUILD=${APP_BUILD} \
    APP_BUILT_AT=${APP_BUILT_AT} \
    APP_COMMIT_SHA=${APP_COMMIT_SHA}

EXPOSE 3000
# Distroless ENTRYPOINT is the node binary — CMD is just the script path
CMD ["server.js"]