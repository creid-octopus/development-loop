# AGENTS.md

This repo holds developmentloop v2. It's a small Kubernetes service with a Postgres database. The service shows the Octopus Deploy golden path from build to Production.

The full plan lives in the [developmentloop v2 plan](./agent-files/plan.md) doc. Read the Status section first. Then read the layer you're working on before you change anything.

## Related repos

| Repo | What lives there |
| --- | --- |
| `octopus-base-infrastructure` | Platform Hub process templates, project templates, and policies (`.octopus/`) |
| `local-workloads` | Local Postgres, Tentacle, worker, and the OpenTelemetry stack (Docker Compose) |
| `composite-development-loop` | The v1 app. Use it as a reference only. Don't copy its Azure App Service process |

Deployment process changes go in `octopus-base-infrastructure` as process templates. Each Octopus project in this repo has a Config as Code folder in `.octopus/`. Those folders compose published templates. Don't add inline steps to them unless the plan says to.

## Commands

```bash
cd src && npm install && npm test        # unit tests, no Docker
docker compose up --build                # database, migrations, app, telemetry
scripts/test-local.sh                    # end to end check of the local loop
scripts/migrate.sh info                  # Flyway against DATABASE_URL, read only
scripts/scan-migrations.sh               # scan migrations for risky SQL
scripts/check-k8s-health.sh              # /health/db on every container track and environment (needs the port-forward)
scripts/check-server-health.sh           # /health/db on the Linux server path, ports 3101 to 3103
```

Local details: [`docs/local-development.md`](docs/local-development.md).

## Rules

### Environments

- Use exactly `Development`, `Test`, and `Production`. Never `Dev`, `DevEnv`, or lower-case names.
- Pull request environments are named `pr-<number>` from the `PullRequestNumber` release custom field.

### Database

- Every schema change is a Flyway migration in `db/migrations/`. Never edit a migration that has shipped. An applied `R__` file can't be deleted without a `flyway repair`. How migrations behave on deploy, redeploy, and rollback: [`docs/database-migrations.md`](docs/database-migrations.md).
- Write migrations as expand and contract. The previous app version must still work against the new schema.
- Never put a destructive change (`DROP`, column rename, `NOT NULL` without a default) in the same release as the code that stops using it.
- Each tenant gets its own database. The tenant key names the database and the user.
- Migrations run on an Octopus worker before the app deploys. The app never migrates on startup.
- Three logins touch a database: server admin, database owner, and app user. The admin only runs the provisioning runbook. The owner runs Flyway. The app user reads and writes rows and owns nothing. Details: [`docs/database-roles.md`](docs/database-roles.md).
- Roles, databases, and grants come from the `Create and provision Postgres database` runbook, not the deployment. The deployment only verifies them.
- The app connects as the app user. Never point the app at the owner or admin login.
- The deployment locks `flyway_schema_history` against writes by the app user right after Flyway runs. Keep the `Lock migration history` step after the migration step.
- The three delivery tracks share one database per environment. Deprovisioning one track removes the database for all three. Pull request environments are the exception: each track gets its own `developmentloop_<track>_pr_<number>` database.
- Never reuse the admin password for another login.

### Rollbacks

- Roll forward by default. Rollback means redeploying an older release, and it's a last resort.
- A rollback pauses twice: `Confirm rollback` in `predeploy-boilerplate`, then the DBA review before migrate. Keep `predeploy-boilerplate` first in every process, and keep the rollback expression on `Postgres.Review.Policy`.
- Migrate still runs on a rollback after DBA approval. It never undoes versioned migrations, and it can apply older `R__` files again.
- Don't write Flyway undo scripts unless a task asks for them.

### Observability

- The app sends OTLP to an OpenTelemetry Collector. Set the endpoint with `OTEL_EXPORTER_OTLP_ENDPOINT`. Never hard-code a vendor endpoint.
- Locally the Collector feeds Prometheus, Tempo, and Grafana. Datadog joins later through the Collector.
- Failed requests must set span status to error. The error rate in the back-end has to match what the app returns.
- Keep the `/simulate/*` failure endpoints. Demos depend on them.

### Builds and releases

- GitHub Actions builds the image and the Flyway package, pushes build information, and creates the release.
- The server path has its own workflow, `build-package.yml`. It builds the app zip, the SBOM zip, and the Flyway zip at version `1.1.<run>`. The container path stays at `1.0.<run>`. Details: [`docs/server-deployment.md`](docs/server-deployment.md).
- A server package never contains the Node.js runtime. Keep the minimum runtime check in the deployment.
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
