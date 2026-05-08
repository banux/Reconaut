#!/usr/bin/env bash
# scripts/check_rest_allowlist_test.sh - tests du linter REST allowlist.
#
# Cf. scripts/check_rest_allowlist.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_rest_allowlist.sh > /tmp/check_rest_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_rest_out
    fail=1
  fi
}

# --- 1. Etat de base : routes existantes (allowlist + transition) -> OK ---
assert_lint "current routes -> exit 0" 0

# --- 2. Nouvelle route REST hors allowlist -> exit != 0 ---
ROUTES_FILE="apps/api/config/routes.rb"
cp "$ROUTES_FILE" "$ROUTES_FILE.bak"

# Insere une nouvelle route avant la ligne `end` finale.
sed -i.tmp '/^end$/i\
  get "/reports", to: "reports#index"' "$ROUTES_FILE"
rm -f "$ROUTES_FILE.tmp"

assert_lint "new GET /reports route -> exit != 0" 1

mv "$ROUTES_FILE.bak" "$ROUTES_FILE"

# --- 3. Nouvelle route MCP (sous /mcp/) -> OK ---
cp "$ROUTES_FILE" "$ROUTES_FILE.bak"

# La route MCP doit matcher l'allowlist.
sed -i.tmp '/post "\/tools\/:tool_name"/a\
    get "/tools/:tool_name", to: "mcp/tools#describe"' "$ROUTES_FILE"
rm -f "$ROUTES_FILE.tmp"

assert_lint "new GET /mcp/tools/:name -> exit 0 (allowlist match)" 0

mv "$ROUTES_FILE.bak" "$ROUTES_FILE"

# --- 4. Nouvelle route auth (DELETE /auth/sessions/:id) -> OK ---
cp "$ROUTES_FILE" "$ROUTES_FILE.bak"

sed -i.tmp '/post   "\/sessions"/a\
    delete "/sessions/:id", to: "auth/sessions#destroy"' "$ROUTES_FILE"
rm -f "$ROUTES_FILE.tmp"

assert_lint "new DELETE /auth/sessions/:id -> exit 0" 0

mv "$ROUTES_FILE.bak" "$ROUTES_FILE"

# --- 5. Etat propre apres cleanup ---
assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_rest_allowlist tests: KO" >&2
  exit 1
fi

echo "check_rest_allowlist tests: all green"
