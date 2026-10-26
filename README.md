# development-loop

This repo holds the v2 demo service for Octopus Deploy. It's a small Node.js service that shows a "golden path" from a GitHub Actions build to Kubernetes, with Platform Hub templates doing the deployment work.

The service is the reference app for that golden path. It brings together several demos that used to live apart: supply chain checks, Argo CD delivery, database migrations, rollbacks, tenancy, approvals, and app health.

The work is planned in layers. See [`agent-files/plan.md`](agent-files/plan.md) for the full plan. Each layer leaves a demo that works.

> **Status:** layer 2, local first. The app, Postgres, Flyway migrations, and the local Grafana stack run with `docker compose up`. The Kubernetes manifests do not use the database yet. The Octopus process templates for the database come next.

## How it fits together

| Repo | Role |
| --- | --- |
| `development-loop` (this repo) | App code, image build, Kubernetes manifests, Argo CD ApplicationSets, and database migrations |
| `octopus-base-infrastructure` | Platform Hub process templates, project templates, and policies |
| `local-workloads` | Local Postgres, Tentacle, worker, and the OpenTelemetry stack |

Deployment steps live in Platform Hub, not in this repo. This repo produces the artifacts that the templates deploy.

## Delivery paths

All three paths deploy the same image. Each one is driven by its own Octopus project built from the Argo CD project template.

| Path | Manifests | Argo CD ApplicationSets | Octopus project |
| --- | --- | --- | --- |
| Raw YAML | `k8s/raw/` | `argocd/*/raw-applications.yaml` | PT - ArgoCD - Raw YAML |
| Kustomize | `k8s/kustomize/` | `argocd/*/kustomize-applications.yaml` | PT - ArgoCD - Kustomize |
| Helm | `k8s/helm/` | `argocd/*/helm-applications.yaml` | PT - ArgoCD - Helm |

The `nonprod` ApplicationSets cover Development and Test. The `prod` ApplicationSets cover Production. Octopus updates the image tag in Git, and Argo CD syncs the change.

## Directory structure

```
.
├── src/                  # Node.js 24 + Express app
│   ├── server.js         # build info at /, /health, and /simulate/* failure endpoints
│   └── instrumentation.js  # OpenTelemetry SDK setup (OTLP over HTTP)
├── db/
│   ├── migrations/       # Flyway migrations (V1 to V3)
│   └── test-fixtures/    # risky SQL used to test the scan script. Never deployed
├── scripts/
│   ├── migrate.sh        # Flyway Community against any Postgres
│   ├── scan-migrations.sh  # text scan for risky SQL
│   └── test-local.sh     # checks the local loop end to end
├── observability/        # Collector, Prometheus, Tempo, and Grafana config
├── Dockerfile            # multi-stage: --target debug (node:24-slim)
│                         #              --target release (distroless)
├── k8s/                  # manifests: raw/, kustomize/, helm/
├── argocd/               # ApplicationSets: nonprod/, prod/
├── tools/
│   └── traffic-job.yaml  # one-off traffic generator for demos
├── docs/                 # attestation, scanning, and workflow decisions
├── agent-files/
│   └── plan.md           # the v2 plan
├── AGENTS.md             # rules for coding agents (CLAUDE.md imports it)
└── .github/
    ├── dependabot.yml    # weekly grouped updates for action versions
    └── workflows/
        ├── ci.yml
        └── build-image.yml
```

## Workflows

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `ci.yml` | Every push and pull request | Runs a Trivy filesystem scan and a dry build of the image. Nothing is pushed |
| `build-image.yml` | Push to `main` with `src/**` or Dockerfile changes, a weekly schedule, or manual dispatch | Builds and pushes the image to GHCR. Generates an SPDX SBOM and pushes it to Octopus. Attests main builds. Scans the pushed image |

A release workflow arrives in layer 2. It will push build information, add release custom fields, and create the Octopus release.

## Built artifacts

| Artifact | Produced by | Format | Destination |
| --- | --- | --- | --- |
| Container image | `build-image.yml` | OCI image | `ghcr.io/creid-octopus/development-loop` |
| SBOM package (`developmentloop-sbom`) | `build-image.yml` | `.zip` (SPDX JSON) | Octopus built-in feed |
| Vulnerability report | `ci.yml`, `build-image.yml` | SARIF | GitHub Security tab |
| Build provenance | `build-image.yml` (main only) | SLSA attestation | GitHub attestation store |

### Image tags

Each build produces 2 tags as well as a `latest` tag for convenience.

```
ghcr.io/creid-octopus/development-loop:latest              # semantic latest, for testing
ghcr.io/creid-octopus/development-loop:1.0.42              # semver, for Octopus references
ghcr.io/creid-octopus/development-loop:1.0.42-sha-a1b2c3d  # SHA-pinned, for manifests
```

Main builds use the `release` (distroless) target. Feature branch builds use `0.0.0-<branch>.<run>` and the `debug` target.

Verify a release attestation:

```bash
gh attestation verify oci://ghcr.io/creid-octopus/development-loop:1.0.42 --repo creid-octopus/development-loop
```

## Running locally

Run the app on its own:

```bash
cd src && npm install && npm run dev
```

Open `http://localhost:3000`. The `/health` endpoint returns the build info as JSON.

Run the container:

```bash
# Debug image (has a shell)
docker build --target debug -t developmentloop-demo:local .
docker run -p 3000:3000 -e APP_ENV=local developmentloop-demo:local

# Release image (distroless)
docker build --target release -t developmentloop-demo:local .
docker run -p 3000:3000 -e APP_ENV=local developmentloop-demo:local
```

Run the whole loop (database, migrations, app, and telemetry):

```bash
docker compose up --build                       # no .env file needed
scripts/test-local.sh                           # checks each piece and explains failures
docker compose --profile traffic up traffic     # optional steady traffic
```

Open the app at `http://localhost:3001` and Grafana at `http://localhost:3100`.

The app reads its database from `DATABASE_URL`, or from the standard `PG*` variables. Pointing it at another database is a change of environment, not code. On Kubernetes the app uses the `PG*` variables and connects as a login that cannot change tables. See [`docs/database-roles.md`](docs/database-roles.md) for the role split and the provisioning runbooks. See [`docs/local-development.md`](docs/local-development.md) for what each service does, how to swap the database, and how to fix common failures.

Run the unit tests (no Docker needed):

```bash
cd src && npm test
```

## Failure simulation

The `/simulate/*` endpoints let you break the app on purpose during a demo. They cover errors, latency, a degraded state, crashes, and out-of-memory. `/simulate/reset` returns the app to normal. Health checks and alerts in later layers depend on these endpoints.

## Octopus authentication

Workflows log in to Octopus with OIDC. There's no API key to store or rotate.

1. GitHub Actions requests a short-lived OIDC token. This needs `id-token: write`.
2. `OctopusDeploy/login@v1` exchanges that token for an Octopus access token. The access token expires when the run ends.
3. Later Octopus steps pick up the token automatically. They need no `server` or `api_key` inputs.

The server URL and service account ID are set as `env` values in each workflow. Neither value is a secret. The service account only trusts tokens issued to this repo.

```yaml
- name: Log in to Octopus Deploy
  uses: OctopusDeploy/login@v1
  with:
    server: ${{ env.OCTOPUS_SERVER_URL }}
    service_account_id: ${{ env.OCTOPUS_SERVICE_ACCOUNT_ID }}
```

New workflows that talk to Octopus should copy this step and the `id-token: write` permission.

## GitHub secrets

| Secret | Description |
| --- | --- |
| `OCTOPUS_SPACE` | Space name or ID |

`build-image.yml` uses `GITHUB_TOKEN` for GHCR automatically. You don't need to configure it.

## Future considerations: OCI-native supply chain

The current supply chain uses GitHub-native tools:

- `actions/attest-build-provenance` for SLSA provenance
- A Trivy SBOM, zipped and pushed to the Octopus built-in feed
- `gh attestation verify` for verification, which needs GitHub API access

The ecosystem is moving toward attaching everything to the image digest in the registry. That makes verification work without GitHub.

### Cosign (Sigstore)

[Cosign](https://github.com/sigstore/cosign) signs images and stores the signatures in the registry next to the image. You can verify them with the `cosign` CLI alone.

```bash
# Sign after push (keyless, using GitHub OIDC)
cosign sign --yes ghcr.io/creid-octopus/development-loop@<digest>

# Verify anywhere
cosign verify ghcr.io/creid-octopus/development-loop:<tag> \
  --certificate-identity-regexp="https://github.com/creid-octopus/development-loop/" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```

Cosign and GitHub attestations work well together. Many pipelines use both.

### SBOM attached to the image

The SBOM can be attached to the image digest with [ORAS](https://oras.land) or Cosign, instead of being pushed to Octopus as a zip:

```bash
cosign attach sbom --sbom sbom.spdx.json ghcr.io/creid-octopus/development-loop@<digest>

# Or with ORAS
oras attach ghcr.io/creid-octopus/development-loop@<digest> \
  --artifact-type application/spdx+json \
  sbom.spdx.json
```

The SBOM then travels with the image. Any tool that reads OCI referrers can find it.

### Why not now

- Octopus support for OCI referrers isn't mature yet. The packaged SBOM is more reliable for the demo.
- Keyless Cosign signing adds verification work in the deployment steps.
- The current attestation approach is enough while the pipeline already needs GitHub API access.
