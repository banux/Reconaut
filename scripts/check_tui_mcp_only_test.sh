#!/usr/bin/env bash
# scripts/check_tui_mcp_only_test.sh — tests du linter MCP-only TUI.
#
# Cf. scripts/check_tui_mcp_only.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_tui_mcp_only.sh > /tmp/check_tui_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_tui_out
    fail=1
  fi
}

# 1. État de base : OK.
assert_lint "current TUI sources -> exit 0" 0

# 2. Inject une URL hors allowlist dans scope.go -> exit != 0.
TARGET="apps/tui/cmd/reconautctl/scope.go"
cp "$TARGET" "$TARGET.bak"

# Insère une chaîne "/scopes" dans le fichier.
sed -i.tmp 's|func runScopeList|var legacyURL = "/scopes"\n\nfunc runScopeList|' "$TARGET"
rm -f "$TARGET.tmp"

assert_lint "rogue \"/scopes\" inserted -> exit != 0" 1

mv "$TARGET.bak" "$TARGET"

# 3. Une URL /mcp/* explicitement ajoutée -> OK.
cp "$TARGET" "$TARGET.bak"

sed -i.tmp 's|func runScopeList|var safeURL = "/mcp/tools/list_scopes"\n\nfunc runScopeList|' "$TARGET"
rm -f "$TARGET.tmp"

assert_lint "explicit /mcp/* literal -> exit 0" 0

mv "$TARGET.bak" "$TARGET"

# 4. État propre.
assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_tui_mcp_only tests: KO" >&2
  exit 1
fi

echo "check_tui_mcp_only tests: all green"
