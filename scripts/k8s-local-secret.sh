#!/usr/bin/env bash
# Creates the namespace and the database password Secret on the current kubectl context.
# Local use only. A real cluster gets this Secret from cluster bootstrap.
#
# Usage:
#   DB_PASSWORD='...' scripts/k8s-local-secret.sh [development|test|production]
#
# Defaults match the Octopus "Postgres - Local DB" project:
#   database  test_db_<env>
#   user      test_db_login_<env>
#   host      host.docker.internal:5432  (Postgres from local-workloads, seen from kind)
set -euo pipefail

ENVIRONMENT="${1:-development}"
: "${DB_PASSWORD:?Set DB_PASSWORD to the value of Project.Postgres.LoginPassword}"
DB_HOST="${DB_HOST:-host.docker.internal}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-test_db_${ENVIRONMENT}}"
DB_USER="${DB_USER:-test_db_login_${ENVIRONMENT}}"
NAMESPACE="developmentloop-demo-${ENVIRONMENT}"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" create secret generic developmentloop-db \
  --from-literal=PGPASSWORD="$DB_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -

echo "Secret developmentloop-db (PGPASSWORD) is set in $NAMESPACE."
echo "The ConfigMap needs PGHOST=${DB_HOST} PGPORT=${DB_PORT} PGDATABASE=${DB_NAME} PGUSER=${DB_USER}."
echo "In Octopus those come from variable substitution. For a local apply, replace the #{...} values first."
