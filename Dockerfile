# ── Build stage (shared by both targets) ─────────────────────
FROM node:24.22.1-slim AS build
WORKDIR /app
COPY src/package*.json ./
RUN npm ci --omit=dev
COPY src/ .

# ── Debug target (feature / RC builds) ───────────────────────
# Full node:24.22.1-slim — has shell, curl, npm for exec/debugging
FROM node:24.22.1-slim AS debug
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
# Source of the Node.js binary for the release image.
# Pinned so a runtime fix is one tag bump. Dependabot updates this tag.
FROM node:24.22.1-slim AS node-bin

# Distroless — no shell, no package manager, minimal attack surface.
# The cc base has the C++ runtime that Node needs. The nodejs distroless image
# ships an older Node, so the binary comes from the pinned stage above.
FROM gcr.io/distroless/cc-debian12 AS release
WORKDIR /app
COPY --from=node-bin /usr/local/bin/node /usr/local/bin/node
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
# ENTRYPOINT is the node binary — CMD is just the script path
ENTRYPOINT ["/usr/local/bin/node"]
CMD ["server.js"]