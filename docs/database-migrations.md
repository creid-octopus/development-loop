# Database migrations and rollbacks

This page records how Flyway migrations behave on deploy, redeploy, and rollback, and the decisions that follow from it. The findings come from tests run on October 28, 2026, locally and in Development on PT - Raw YAML.

For the logins and the provisioning runbooks, see [`database-roles.md`](database-roles.md).

## Decisions

- **Roll forward by default.** Fix the problem in a new release. Roll back only when it is absolutely necessary. See [The hotfix myth](https://octopus.com/blog/the-hotfix-myth).
- **Rollback never undoes versioned migrations.** The older app runs on the newer schema. Write every migration as expand and contract so that works.
- **A rollback needs DBA approval before migrate.** Running migrate on a rollback is not harmless. It can fail the deployment or quietly revert repeatable migrations. See [Flyway behavior](#flyway-behavior). The DBA review pauses after the review step, so the approver sees the Flyway state first. Reject to stop the rollback and roll forward instead.
- **A rollback pauses for confirmation.** The `Confirm rollback` step in `predeploy-boilerplate` explains what a rollback does and doesn't undo before anything changes.
- **A redeploy behaves like a deploy.** Database steps run on a redeploy. Flyway does nothing when the schema is up to date.

## How a deployment runs migrations

| Step | Runs on | What it does |
| --- | --- | --- |
| `Calculate Deployment Mode` (`predeploy-boilerplate`) | Every run | Compares the release with the last one in the environment. Sets `DeploymentMode` to `Deploy`, `Redeploy`, or `Rollback` |
| `Confirm rollback` (`predeploy-boilerplate`) | Rollback only | Manual intervention. Approve to continue, reject to roll forward instead |
| `Verify database ready` | Every run | Checks the database, the owner, and the app login exist |
| `Review pending migrations` | Every run | Runs `flyway info` and scans pending files for risky SQL. Read only. A policy can require it because it never skips |
| `DBA review` | Every rollback, and when the review finds risky SQL | Pauses for approval. The project sets `Postgres.Review.Policy` to `always` on a rollback and `risky` otherwise |
| `Flyway - Migrate` | Every run, after any DBA approval | Applies pending migrations |
| `Lock migration history` | Every run | Revokes writes on `flyway_schema_history` from the app login |

The rollback DBA review is set in PT - Raw YAML only. Copy the `Postgres.Review.Policy` expression to the other projects after it is confirmed:

```
#{if Octopus.Action[Predeploy Boilerplate-Calculate Deployment Mode].Output.DeploymentMode == "Rollback"}always#{else}risky#{/if}
```

## Deployment mode

`predeploy-boilerplate` holds an inline copy of the community step template Calculate Deployment Mode (`CommunityActionTemplates-115`, version 5).

### Reading the outputs

Inside a process template, a step is named `<usage name>-<template step name>`. The outputs use that name:

```
#{Octopus.Action[Predeploy Boilerplate-Calculate Deployment Mode].Output.RunOnDeployOrRedeploy}
```

The usage name comes from each project, so a template must not hard-code it. Pass the condition into a template as a parameter. A variable that holds the expression resolves to a plain `True` or `False` in a variable run condition.

Inside one template, the short step name also resolves, for example `Octopus.Action[Calculate Deployment Mode]`.

| Output | Deploy | Redeploy | Rollback |
| --- | --- | --- | --- |
| `RunOnDeploy` | True | False | False |
| `RunOnRedeploy` | False | True | False |
| `RunOnRollback` | False | False | True |
| `RunOnDeployOrRedeploy` | True | True | False |

The rollback DBA review reads `DeploymentMode` directly. Use `RunOnDeployOrRedeploy` for a step that should never run on a rollback.

### How the mode is decided

- The script drops the pre-release tag before it compares. `1.0.16-probe` and `1.0.16` are the same version, so the second is a redeploy.
- A redeploy right after a rollback is still a rollback. The script compares with the release before the current one. The mode stays `Rollback` until a higher version deploys. Each redeploy while rolled back pauses for DBA review again.
- A failed deployment does not change the baseline. After a failed rollback attempt, the next higher release is a deploy.
- The first deploy to an environment fails. There is no previous release to compare with. Pull request environments need a guard before layer 6.
- `VersionChange` is unreliable. It stays `Identical` on a normal deploy. Don't use the `RunOn*VersionChange` outputs.

## Flyway behavior

Flyway Community 13.10.3 on Postgres 17.

| Test | What happened | Where |
| --- | --- | --- |
| Rollback to a package without a newer versioned migration | V4 shows as `Future`. `migrate` warns that the schema is newer than the latest migration, then changes nothing | Local |
| Rollback to a package without an applied `R__` file | `info` works. `validate` and `migrate` fail: "Detected applied migration not resolved locally" | Local, `ServerTasks-45582` |
| Redeploy the same package | "Schema is up to date. No migration necessary." | Local, `ServerTasks-45581` |
| Rollback after an `R__` change | The older `R__` applies again without a warning | Local, `ServerTasks-45579` |
| A migration fails partway through a run | Earlier migrations stay applied. The failed one rolls back fully and leaves no history row. A fixed file applies on retry | Local |
| A hotfix version lower than an applied one | `migrate` fails unless `outOfOrder` is true | Local |

### What `flyway info` reports

The review step reads these states from `flyway info -outputType=json`.

| Situation | Rows for the repeatable `items summary` |
| --- | --- |
| Roll forward after an `R__` change | `Outdated` (applied) and `Pending` (will run) |
| Rollback after an `R__` change | `Superseded`, `Outdated`, and `Pending` |
| Rollback to a package without the `R__` file | `Superseded` and `Missing` |

Only `Pending` rows run. On a rollback, a `Missing` row means migrate will fail, and a `Pending` repeatable means migrate will revert it. A `Future` versioned migration is safe.

## What a rollback does

- **It runs the old release's process.** A release keeps the process template versions from when it was created. Fixes, run conditions, and checks added later don't apply. A rollback to a release created before migrate had a run condition will run migrate.
- **It doesn't roll back the database.** Versioned migrations stay applied.
- **It can revert repeatable migrations.** Views, functions, and procedures go back to the old version if migrate runs.
- **It can fail on migrations it doesn't know.** A missing `R__` file fails Flyway validation. The deployment stops before the app changes.
- **It brings back the old app,** including the bugs and vulnerabilities fixed since.

Two rollbacks won't pause at `Confirm rollback` or the rollback DBA review:
- a rollback to a release created before those checks existed. The release keeps its old process and its old project settings
- a rollback that shares a base version with the current release, which counts as a redeploy

## Writing migrations

- **Versioned (`V<n>__`).** Never edit a file that has applied anywhere. A file that failed and rolled back never applied, so fixing it in place is fine.
- **Expand and contract.** Ship a destructive change (`DROP`, a rename, `NOT NULL` without a default) only after no running app version depends on the old shape.
- **Repeatable (`R__`).** It runs again whenever the file changes. Once applied, it can't leave `db/migrations` without a `flyway repair`. Every older package fails migrate after it's gone.
- **Hotfix migrations** take the next version number. A lower number fails unless `outOfOrder` is on.

## Known issues and planned work

- **Rollback hazard check.** On a rollback, have the review step flag `Missing` rows and `Pending` repeatables in an output such as `RollbackHazard`, then notify or pause. It reads Flyway's state, not release numbers, so it also catches a rollback that counts as a redeploy.
- **Silent review.** Until then, the review step reports "No pending migrations" one step before a rollback to a package without an applied `R__` fails.
- **Version bumps for new Flyway packages.** A release with a new Flyway package should get a new patch version, so an older package never shares a base version with a newer one.
- **Calculate Deployment Mode fixes.** The first-deploy guard and the two script bugs (`VersionChange`, a typo in a log line) belong in `predeploy-boilerplate`. Fix them after the community template update test in the plan.

## Reproducing the Flyway tests locally

Start a scratch Postgres, then run `scripts/migrate.sh` with `FLYWAY_LOCATIONS` pointed at a folder of migration files. The path is relative to the repo root.

```bash
docker run -d --rm --name flyway-scratch -e POSTGRES_PASSWORD=scratch -e POSTGRES_DB=scratch -p 55432:5432 postgres:17
export DATABASE_URL=postgres://postgres:scratch@localhost:55432/scratch

scripts/migrate.sh migrate                              # apply db/migrations
FLYWAY_LOCATIONS=<older copy> scripts/migrate.sh info   # see the state an older package reports

docker stop flyway-scratch
```

Keep test migrations out of `db/migrations`. A file that applies in Development can never change.
