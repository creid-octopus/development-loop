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

## Project variables

| Variable | Kind | Notes |
| --- | --- | --- |
| `Project.Postgres.OwnerRole` | Text | `developmentloop_owner_<env>` |
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

- The app user keeps write access on `flyway_schema_history` until the provision runbook runs again after the first migration. Flyway creates that table after the grants run. The next run revokes the write access.
- Resetting an environment loses its data. Run the deprovision runbook, then the provision runbook, then deploy. The deprovision steps refuse to run in Production.
- Password rotation is a runbook run. A deployment no longer resets the passwords.

## Why not create the database in the deployment

A deployment that creates roles needs admin rights on every run. That grants far more access than a migration needs. Splitting the work keeps the admin password out of the deployment path. It also matches how most teams run databases, where Terraform, an operator, or a managed service owns provisioning.
