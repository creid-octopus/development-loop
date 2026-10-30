# Database roles and provisioning

This page records how the Postgres roles are split and why. It also records how provisioning and deployment divide the work.

## Decision

Three logins touch each database. Each login has one job.

| Login | Name | Can do | Used by |
| --- | --- | --- | --- |
| Server admin | `postgres-local-admin` account | Everything on the server | The provisioning runbook only |
| Database owner | `developmentloop_owner_<env>` | Change the schema of one database | Flyway migrations |
| App user | `developmentloop_app_<env>` | Read and write rows | The running app |

The app user owns nothing. A bug or SQL injection in the app can read and change data. The app user cannot drop or alter a table.

Never reuse the admin password for another login. The admin is a superuser.

## Provisioning and deployment are separate

Roles, databases, and grants are one time work. Migrations run on every deployment.

| Work | Where it lives | When it runs |
| --- | --- | --- |
| Create roles, database, and grants | Runbook `Create and provision Postgres database` | Once per environment, and after any reset |
| Delete the database and roles | Runbook `Deprovision Postgres database` | To reset an environment or remove an ephemeral one |
| Check the database is ready | Deployment step `Verify database ready` | Every deployment, before Flyway |
| Apply migrations | Deployment steps `Run Flyway migrations` | Every deployment |
| Lock the migration history | Deployment step `Lock migration history` | Every deployment, right after Flyway |
| Create the app Secret | Deployment step `Create application secrets` | Every deployment |

The deployment never creates roles or databases. When provisioning is missing, `Verify database ready` fails with the name of the runbook to run.

## What the runbook does

1. Creates the owner role.
2. Creates the app role.
3. Creates the database owned by the owner role. An existing database gets its owner repaired.
4. Grants the app role access. The grants cover `CONNECT`, `USAGE` on schema `public`, and `SELECT`, `INSERT`, `UPDATE`, and `DELETE` on tables.
5. Sets default privileges for tables the owner creates later. New migrations need no extra grant.
6. Verifies the app role. It must connect, have the default privileges, and fail to create a table.

Every step is safe to rerun. Each run resets both role passwords to the project values. A run on a healthy environment changes nothing else.

## Locking the migration history

Flyway records every migration in the table `flyway_schema_history`. The app reads that table to report its schema version. The app must never write it.

Flyway creates the table during the first migration. That is after the provisioning runbook has run. Default privileges then give the app user write access to the new table.

The deployment step `Lock migration history` closes that gap. It runs right after Flyway and connects as the database owner. The owner created the table, so the owner can revoke access. The step revokes `INSERT`, `UPDATE`, `DELETE`, and `TRUNCATE` from the app user. It then checks that the app user can read the table and cannot write it.

The step is safe to run on every deployment. The first deployment to a new database locks the table. No manual rerun of the runbook is needed.

## Three tracks share one database

The raw YAML, Helm, and Kustomize tracks deploy the same app. Each track has its own Octopus project. All three use one database and one pair of app and owner logins in each environment. Provisioning one track provisions the others. Deprovisioning any track removes the database for all three.

Pull request environments are the exception. Each track gets its own database and logins for each `pr-<number>` environment, because each project creates and tears down its own ephemeral environments.

## How the names are built

The database and login names come from a chain of variables:

1. `Helper.EnvironmentLowerCase` is the environment name in lower case, such as `development` or `pr-12`.
2. `Helper.PostgresEnvironmentName` is the part of the name that changes per environment.
   - Development, Test, and Production: the same as `Helper.EnvironmentLowerCase`.
   - Pull request environments (scoped to the `Ephemeral Testing` parent): the track, then the environment name with `-` replaced by `_`, such as `helm_pr_12`.
3. `Project.Postgres.DatabaseName`, `OwnerRole`, and `AppRole` add the `developmentloop_`, `developmentloop_owner_`, and `developmentloop_app_` prefixes.

| Environment | Database | Owner login | App login |
| --- | --- | --- | --- |
| Development | `developmentloop_development` | `developmentloop_owner_development` | `developmentloop_app_development` |
| `pr-12`, Helm track | `developmentloop_helm_pr_12` | `developmentloop_owner_helm_pr_12` | `developmentloop_app_helm_pr_12` |

Pull request environments use the owner and app passwords scoped to `Ephemeral Testing` in `CommonPostgresVariables`, so every pull request shares the same pair.

## Project variables

| Variable | Kind | Notes |
| --- | --- | --- |
| `Project.Postgres.OwnerRole` | Text | `developmentloop_owner_<env>`. See [How the names are built](#how-the-names-are-built) |
| `Project.Postgres.AppRole` | Text | `developmentloop_app_<env>` |
| `Project.Postgres.OwnerPassword` | Sensitive | Set in the Octopus UI. Not in Config as Code |
| `Project.Postgres.AppPassword` | Sensitive | Set in the Octopus UI. Not in Config as Code |
| `Project.Postgres.DatabaseName` | Text | `developmentloop_<env>` |
| `Project.Postgres.Host` | Text | Host the Tentacle and worker use to reach Postgres |
| `Project.Postgres.AppHost` | Text | Host the pod uses to reach Postgres |

Use different values for the owner and app passwords.

## How the app gets its credentials

The manifests set `PGHOST`, `PGPORT`, `PGDATABASE`, and `PGUSER` in a ConfigMap. They set `PGPASSWORD` from the Secret `developmentloop-db`. The raw, Helm, and Kustomize tracks all read that one Secret in each namespace.

Octopus creates the Secret from `k8s/raw/<env>/secrets/database_connection.yaml`. The file holds an Octopus variable, never a real password.

## Known limits

- The app user has write access on `flyway_schema_history` for a short time. The window runs from table creation to the `Lock migration history` step in the same deployment. A failed migration can leave the table unlocked until the next successful deployment.
- The lock step assumes the default Flyway table name. Set the `Postgres.History.Table` parameter when Flyway uses a custom name.
- Resetting an environment loses its data. Run the deprovision runbook, then the provision runbook, then deploy. The deprovision steps refuse to run in Production.
- The deprovision runbook pauses at `Confirm deprovision` before it drops anything. Pull request environments skip the pause (`Project.Deprovision.Confirm` is `False` in `Ephemeral Testing`), so teardown on close and inactivity expiry run unattended. Any other value, or a missing variable, keeps the pause.
- Password rotation is a runbook run. A deployment no longer resets the passwords.

## Why not create the database in the deployment

A deployment that creates roles needs admin rights on every run. That grants far more access than a migration needs. Splitting the work keeps the admin password out of the deployment path. It also matches how most teams run databases, where Terraform, an operator, or a managed service owns provisioning.
