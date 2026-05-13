#!/usr/bin/env bash
# scripts/check_scanner_no_db_access.sh — refuse tout accès Postgres
# côté workers Go (apps/scanner/).
#
# Source de vérité :
#   openspec/changes/remote-scanner-agents/specs/scanning/spec.md
#     -> Requirement: Workers Go consomment la file via MCP HTTP
#
# Les workers DOIVENT dialoguer EXCLUSIVEMENT avec Rails via MCP HTTP
# (cf. internal/agentclient). Tout import database/sql, pgx, lib/pq
# ou référence à RECONAUT_DATABASE_URL dans le code de prod viole le
# contrat : les workers ne doivent plus connaître Postgres.

set -euo pipefail

cd "$(dirname "$0")/.."

target_dirs=(apps/scanner/internal apps/scanner/cmd)

errors=0

fail() {
  echo "scanner-no-db-access: $1" >&2
  errors=1
}

# Patterns interdits dans le code de prod (.go hors *_test.go).
forbidden_imports='"database/sql"|github\.com/jackc/pgx|github\.com/lib/pq|github\.com/jackc/pgconn'
forbidden_env='RECONAUT_DATABASE_URL'

for dir in "${target_dirs[@]}"; do
  if [[ ! -d "$dir" ]]; then
    continue
  fi
  prod_files=$(find "$dir" -type f -name "*.go" -not -name "*_test.go")
  if [[ -z "$prod_files" ]]; then
    continue
  fi

  # 1. Imports DB interdits.
  hits=$(grep -HnE "$forbidden_imports" $prod_files 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*(//|/\*|\*)' \
    || true)
  if [[ -n "$hits" ]]; then
    fail "import DB interdit détecté dans $dir :"
    echo "$hits" >&2
  fi

  # 2. Référence à RECONAUT_DATABASE_URL (env var DB).
  env_hits=$(grep -HnE "$forbidden_env" $prod_files 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*(//|/\*|\*)' \
    || true)
  if [[ -n "$env_hits" ]]; then
    fail "référence à RECONAUT_DATABASE_URL interdite dans $dir :"
    echo "$env_hits" >&2
  fi
done

if (( errors != 0 )); then
  echo "check_scanner_no_db_access: KO ($errors violations)" >&2
  exit 1
fi

echo "check_scanner_no_db_access: OK"
