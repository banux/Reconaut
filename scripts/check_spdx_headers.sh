#!/usr/bin/env bash
# scripts/check_spdx_headers.sh — vérifie que chaque source Ruby/Go
# du repo porte un en-tête `SPDX-License-Identifier: AGPL-3.0-only`.
#
# Cf. openspec/changes/init-reconaut-platform/tasks.md §1.1.
#
# Le linter scanne :
#   - apps/api/app/**/*.rb, apps/api/lib/**/*.rb,
#     apps/api/db/migrate/**/*.rb, apps/api/config/**/*.rb
#   - apps/scanner/**/*.go, apps/tui/**/*.go
#
# Toute source qui n'a pas la ligne `SPDX-License-Identifier: AGPL-3.0-only`
# dans ses 3 premières lignes fait échouer le check.
#
# Pour ajouter automatiquement les en-têtes manquants :
#   bash scripts/add_spdx_headers.sh

set -euo pipefail

cd "$(dirname "$0")/.."

errors=0
expected="SPDX-License-Identifier: AGPL-3.0-only"

check_file() {
  local f="$1"
  if ! head -3 "$f" | grep -qF "$expected"; then
    echo "spdx-missing: $f" >&2
    errors=$((errors + 1))
  fi
}

while IFS= read -r f; do
  check_file "$f"
done < <(find apps/api/app apps/api/lib apps/api/db/migrate apps/api/config \
              -type f -name "*.rb" 2>/dev/null)

while IFS= read -r f; do
  check_file "$f"
done < <(find apps/scanner apps/tui -type f -name "*.go" 2>/dev/null)

if (( errors > 0 )); then
  echo "" >&2
  echo "check_spdx_headers: KO ($errors fichiers sans en-tête SPDX)" >&2
  echo "Ajouter automatiquement les en-têtes manquants :" >&2
  echo "    bash scripts/add_spdx_headers.sh" >&2
  exit 1
fi

echo "check_spdx_headers: OK"
