#!/usr/bin/env bash
# scripts/check_tui_mcp_only.sh — vérifie que toutes les URLs littérales
# construites dans apps/tui/ commencent par /mcp/, /auth/sessions,
# /auth/api_keys ou /healthz.
#
# Source de vérité :
#   openspec/changes/mcp-as-primary-entrypoint/specs/architecture/spec.md
#     -> Requirement: MCP HTTP+SSE as Primary Entrypoint
#   openspec/changes/mcp-as-primary-entrypoint/tasks.md §3.3
#
# Le linter scanne les chaînes littérales `"/..."` dans le code Go (hors
# fichiers _test.go : les tests peuvent monter des serveurs httptest qui
# servent des chemins arbitraires) et rejette toute URL hors du pacte.

set -euo pipefail

cd "$(dirname "$0")/.."

TUI_DIR="apps/tui"

if [[ ! -d "$TUI_DIR" ]]; then
  echo "check_tui_mcp_only: skip (apps/tui absent)" >&2
  exit 0
fi

errors=0

# Allowlist : tout chemin commençant par l'un de ces préfixes est OK.
ALLOWED_PREFIXES=(
  "/mcp/"
  "/auth/sessions"
  "/auth/api_keys"
  "/healthz"
)

# Cherche dans les fichiers .go non-test des littéraux qui ressemblent
# à des URLs absolues : "/xyz" (commence par / sans alnum à droite du
# slash final pour éviter les regex / chemins de fichiers Unix). On
# extrait avec une regex assez laxiste puis on filtre.

mapfile -t candidates < <(
  find "$TUI_DIR" -type f -name '*.go' ! -name '*_test.go' \
    -exec grep -nE '"/[A-Za-z][A-Za-z0-9/_-]*"' {} \;
)

for line in "${candidates[@]}"; do
  # line format: <file>:<lineno>:<content>
  # On extrait toutes les chaînes "/..." de la ligne.
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue

    matched=0
    for prefix in "${ALLOWED_PREFIXES[@]}"; do
      if [[ "$url" == "$prefix"* ]]; then
        matched=1
        break
      fi
    done

    if (( matched == 0 )); then
      echo "tui-non-mcp-url: $line" >&2
      echo "  -> URL hors allowlist: $url" >&2
      errors=1
    fi
  done < <(printf '%s\n' "$line" | grep -oE '"/[A-Za-z][A-Za-z0-9/_-]*"' | tr -d '"')
done

if (( errors != 0 )); then
  echo "" >&2
  echo "check_tui_mcp_only: KO" >&2
  echo "Le binaire reconautctl ne DOIT appeler que des URLs sous /mcp/," >&2
  echo "ou les routes d'auth bootstrap (/auth/sessions, /auth/api_keys)" >&2
  echo "ou le healthcheck (/healthz). Cf. openspec/changes/mcp-as-primary-entrypoint/." >&2
  exit 1
fi

echo "check_tui_mcp_only: OK"
