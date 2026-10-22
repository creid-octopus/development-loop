# Local development

This page explains what runs on your machine and why. Read it once. After that, `README.md` has the commands.

## What `docker compose up` starts

```
                         ┌──────────┐   migrate    ┌──────────┐
                         │  flyway  │ ───────────▶ │ postgres │ :5433
                         └──────────┘   (once)     └────▲─────┘
                                                        │ SQL
┌────────┐  HTTP :3001  ┌─────────┐  OTLP :4318   ┌─────┴────┐
│ you /  │ ───────────▶ │   app   │ ────────────▶ │collector │
│ traffic│              └─────────┘               └──┬────┬──┘
└────────┘                                   traces │    │ metrics (app + spanmetrics)
                                                    ▼    ▼
                                               ┌──────┐ ┌────────────┐
                                               │tempo │ │ prometheus │ :9090
                                               └──┬───┘ └─────┬──────┘
                                                  └─────┬─────┘
                                                   ┌────▼────┐
                                                   │ grafana │ :3100
                                                   └─────────┘
```

| Service | Job | Why it exists |
| --- | --- | --- |
| `postgres` | Holds the data | The app needs a real database to migrate and roll back |
| `flyway` | Applies `db/migrations`, then exits | Migrations run before the app. The app never changes the schema |
| `app` | The service on `localhost:3001` | Starts only after `flyway` succeeds |
| `collector` | Receives telemetry from the app | The app talks to one endpoint. Back-ends change behind it |
| `prometheus` | Stores metrics | Includes request and error rates computed from spans |
| `tempo` | Stores traces | Shows what one request did |
| `grafana` | Dashboard on `localhost:3100` | No login. Opens on the "developmentloop app health" dashboard |

## The two ideas to hold on to

**1. The database is just a connection.** The app reads `DATABASE_URL` (or `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`). Nothing else in the code knows where Postgres runs. Compose points it at the `postgres` container. A later Kubernetes deployment points it at an in-cluster Postgres. Nothing in the app changes.

**2. Migrations are separate from the app.** Flyway runs first and records every migration in a table called `flyway_schema_history`. The app reads that table and reports the newest version in `/health`. The version shows what the database is at. The `version` field shows what the app is at. The two can differ, and that gap is what rollback demos are about.

## Check that it works

```bash
docker compose up --build        # terminal 1
scripts/test-local.sh            # terminal 2
```

`test-local.sh` prints one line per check and says what a failure means. It checks the app, the database connection, the schema version, the API, the failure simulator, and that telemetry reaches Prometheus.

Look at the same things by hand:

| What | Where |
| --- | --- |
| App banner and build info | http://localhost:3001 |
| Health, database status, schema version | http://localhost:3001/health |
| Readiness that includes the database | http://localhost:3001/health/db |
| Items stored in Postgres | http://localhost:3001/api/items |
| Dashboard | http://localhost:3100 |
| Raw metrics query | http://localhost:9090 |

## Pointing at a different database

Skip the `postgres` and `flyway` services and give the app a different connection:

```bash
# Run only the app and the telemetry stack. --no-deps leaves postgres and flyway out.
DATABASE_URL=postgres://user:password@host:5432/dbname \
  docker compose up --build --no-deps app collector prometheus tempo grafana
```

Inside a container `localhost` means the container itself. Use `host.docker.internal` for a database on your machine.

Migrate it with the same files:

```bash
DATABASE_URL=postgres://user:password@host:5432/dbname scripts/migrate.sh info      # read only
DATABASE_URL=postgres://user:password@host:5432/dbname scripts/migrate.sh migrate
```

Use `info` first. It lists which migrations are applied and which are pending.

To use the `local-workloads` Postgres on port 5432, set `PGHOST=host.docker.internal PGPORT=5432` and the credentials from that repo's `.env`.

## Migrations

Files live in `db/migrations`.

| File | Kind | What it does |
| --- | --- | --- |
| `V1__init.sql` | Create | The `items` table |
| `V2__add_items_description.sql` | Expand | A nullable column. The previous app version still works |
| `V3__seed_items.sql` | Data | Three sample rows |

Rules the folder follows:

- Never edit a migration that has run anywhere. Add the next version.
- Every change must work with the previous app version. Add first. Remove in a later release.

### Scan for risky SQL

Flyway Community has no dry-run report. `scripts/scan-migrations.sh` fills that gap with a text scan.

```bash
scripts/scan-migrations.sh                     # all migrations
scripts/scan-migrations.sh --after 3           # only versions after 3
scripts/scan-migrations.sh db/test-fixtures/risky   # see what a finding looks like
```

Exit code `0` means nothing found. Exit code `3` means the report lists risky statements. The scan reads text only. A clean result does not prove a migration is safe.

## Tests without Docker

```bash
cd src && npm test
```

These tests need no database. They cover what the app does when the database is missing, wrong, or down.

## When something fails

| Symptom | Likely cause | Check |
| --- | --- | --- |
| `flyway` exits with an error | Two files share a version, or a file changed after it ran | `docker compose logs flyway` |
| App never starts | `flyway` failed. The app waits for it | `docker compose ps` |
| `/health` shows `unreachable` | Wrong `DATABASE_URL`, or Postgres is down | `docker compose logs postgres` |
| `/health` shows `schemaVersion: null` | Flyway has not run against this database | `scripts/migrate.sh info` |
| `/api/items` returns "schema does not match the app" | The app is newer than the schema | Run the migrations |
| Grafana panels are empty | No traffic yet. Metrics lag by 10 to 20 seconds | `docker compose --profile traffic up traffic` |
| Port 5433 in use | Another Postgres is running | Change the port mapping in `docker-compose.yml` |
