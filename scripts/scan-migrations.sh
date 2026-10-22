#!/usr/bin/env bash
# Scans Flyway migration files for risky SQL and prints a report.
#
# Flyway Community has no dry-run report or `check` command. This script covers
# the part the plan needs: tell a person when a migration could lose data or
# break the previous app version.
#
# Usage:
#   scripts/scan-migrations.sh [--after VERSION] [DIR]
#
#   DIR        folder with V__ migrations (default: db/migrations)
#   --after N  only scan versions greater than N. Use the schema version that
#              /health reports so only pending migrations are scanned.
#
# Exit codes (the caller can tell "risky" from "broken"):
#   0  nothing risky found
#   3  risky statements found. The report lists them
#   2  bad usage or unreadable folder
#
# What counts as risky. Every rule maps to the expand and contract policy in
# AGENTS.md: the previous app version must still work after the migration.
#   DROP TABLE|COLUMN|SCHEMA|DATABASE   removes data or a column the old app reads
#   TRUNCATE                            removes data
#   DELETE without WHERE                removes data
#   RENAME                              old app still uses the old name
#   ALTER COLUMN ... TYPE               can rewrite the table or fail on data
#   SET NOT NULL                        old app may still write NULL
#   ADD COLUMN ... NOT NULL no DEFAULT  old app inserts fail
#
# This is a text scan. It reads statements, not intent. A clean result does not
# prove a migration is safe. A finding does not prove it is unsafe.

set -euo pipefail

after=""
dir="db/migrations"
while [ $# -gt 0 ]; do
  case "$1" in
    --after) after="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) dir="$1"; shift ;;
  esac
done

[ -d "$dir" ] || { echo "folder not found: $dir" >&2; exit 2; }

# Version of a file: V12__name.sql -> 12. Repeatable migrations (R__) have none.
version_of() {
  local base
  base="$(basename "$1")"
  base="${base#V}"
  echo "${base%%__*}" | tr '_' '.'
}

# True when $1 is greater than $2 using version ordering.
version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

findings=0
scanned=0

echo "## Migration scan"
echo
echo "Folder: \`$dir\`${after:+ · only versions after $after}"
echo

# Sorted so the report is stable between runs.
while IFS= read -r file; do
  base="$(basename "$file")"
  if [[ "$base" == V* ]]; then
    v="$(version_of "$file")"
    if [ -n "$after" ] && ! version_gt "$v" "$after"; then continue; fi
  elif [[ "$base" != R__* ]]; then
    continue
  fi
  scanned=$((scanned + 1))

  # Strip -- comments and collapse whitespace so rules match across lines.
  # Statements are split on ; so one rule cannot match across two statements.
  stripped="$(sed -E 's/--.*$//' "$file" | tr '\n' ' ' | tr -s '[:space:]' ' ')"

  file_findings=()
  while IFS= read -r stmt; do
    s="$(echo "$stmt" | sed -E 's/^ +| +$//g')"
    [ -z "$s" ] && continue
    lower="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
    reason=""
    case "$lower" in
      *"drop table"*|*"drop column"*|*"drop schema"*|*"drop database"*) reason="drops data or a column the previous app may read" ;;
      "truncate"*|*" truncate "*) reason="removes all rows" ;;
      *" rename "*) reason="renames something the previous app still uses" ;;
      *"set not null"*) reason="old app may still write NULL" ;;
      *"alter column"*" type "*) reason="can rewrite the table or fail on existing data" ;;
    esac
    # DELETE FROM with no WHERE.
    if [ -z "$reason" ] && [[ "$lower" == "delete from"* ]] && [[ "$lower" != *" where "* ]]; then
      reason="deletes all rows"
    fi
    # ADD COLUMN ... NOT NULL without DEFAULT.
    if [ -z "$reason" ] && [[ "$lower" == *"add column"* ]] && [[ "$lower" == *"not null"* ]] && [[ "$lower" != *" default "* ]]; then
      reason="new NOT NULL column without a default breaks inserts from the previous app"
    fi
    [ -n "$reason" ] && file_findings+=("- \`${s:0:120}\` — $reason")
  done < <(echo "$stripped" | tr ';' '\n')

  if [ ${#file_findings[@]} -gt 0 ]; then
    findings=$((findings + ${#file_findings[@]}))
    echo "### $base"
    printf '%s\n' "${file_findings[@]}"
    echo
  fi
done < <(find "$dir" -maxdepth 1 -type f -name '*.sql' | sort -V)

echo "Scanned $scanned file(s). Risky statements: $findings."

# Make the result usable from Octopus: the caller can read this file.
if [ -n "${SCAN_RESULT_FILE:-}" ]; then
  echo "$findings" > "$SCAN_RESULT_FILE"
fi

[ "$findings" -eq 0 ] || exit 3
