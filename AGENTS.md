# AGENTS.md

This repo holds developmentloop v2. It's a small Kubernetes service with a Postgres database. The service shows the Octopus Deploy golden path from build to Production.

The full plan lives in the [developmentloop v2 plan](./agent-files/plan.md) doc. Read the layer you're working on before you change anything.

## Related repos

| Repo | What lives there |
| --- | --- |
| `octopus-base-infrastructure` | Platform Hub process templates, project templates, and policies (`.octopus/`) |
| `local-workloads` | Local Postgres, Tentacle, worker, and the OpenTelemetry stack (Docker Compose) |
| `composite-development-loop` | The v1 app. Use it as a reference only. Don't copy its Azure App Service process |

Deployment process changes go in `octopus-base-infrastructure` as process templates. Don't add steps to this repo's `.octopus/` folder unless the plan says to.

## Layout

```
src/            App code (Node 24, Express)
db/migrations/  Flyway migrations (V__ and R__ files)
k8s/            Kubernetes manifests
.github/        GitHub Actions workflows
docs/           Notes and decisions
```

Update this tree when the layout changes.

## Commands

Fill these in during layer 2.

```bash
npm install
npm test
npm run dev
docker compose up      # app + local dependencies
```

## Rules

### Environments

- Use exactly `Development`, `Test`, and `Production`. Never `Dev`, `DevEnv`, or lower-case names.
- Pull request environments are named `pr-<number>` from the `PullRequestNumber` release custom field.

### Database

- Every schema change is a Flyway migration in `db/migrations/`. Never edit a migration that has shipped.
- Write migrations as expand and contract. The previous app version must still work against the new schema.
- Never put a destructive change (`DROP`, column rename, `NOT NULL` without a default) in the same release as the code that stops using it.
- Each tenant gets its own database. The tenant key names the database and the user.
- Migrations run on an Octopus worker before the app deploys. The app never migrates on startup.

### Rollbacks

- Rollback means redeploying an older release. Database steps skip on rollback through `RunOnDeploy` run conditions.
- Don't write Flyway undo scripts unless a task asks for them.

### Observability

- The app sends OTLP to an OpenTelemetry Collector. Set the endpoint with `OTEL_EXPORTER_OTLP_ENDPOINT`. Never hard-code a vendor endpoint.
- Locally the Collector feeds Prometheus, Tempo, and Grafana. Datadog joins later through the Collector.
- Failed requests must set span status to error. The error rate in the back-end has to match what the app returns.
- Keep the `/simulate/*` failure endpoints. Demos depend on them.

### Builds and releases

- GitHub Actions builds the image and the Flyway package, pushes build information, and creates the release.
- Release custom fields: `PullRequestNumber` and `AIAssisted` (`true` or `false`). Octopus allows at most 10 fields, each 150 characters or less.
- Set `AIAssisted` to `true` when a commit has an AI co-author trailer or the pull request has the `ai-assisted` label.
- Commits made by an agent must include a `Co-authored-by` trailer.

### Secrets

- Never commit secrets, API keys, `.env` files, or Terraform state.
- Octopus API access in CI uses OIDC. Don't add API keys to workflows.

## Working style

- Work one plan layer at a time. Each change should leave a demo that works.
- Keep process templates small and single-purpose. Every input arrives as a parameter.
- Ask before you change shared Platform Hub templates. Other projects use them.
- If something in the plan looks wrong, say so before you build around it.
