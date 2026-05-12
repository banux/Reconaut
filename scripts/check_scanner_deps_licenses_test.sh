#!/usr/bin/env bash
# scripts/check_scanner_deps_licenses_test.sh — tests du linter
# d'audit des licences Go.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_scanner_deps_licenses.sh > /tmp/check_scanner_deps_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_scanner_deps_out
    fail=1
  fi
}

# 1. État de base : OK (toutes les deps figurent dans l'allowlist).
assert_lint "current go.mod -> exit 0" 0

# 2. Injection d'une dep absente de l'allowlist -> exit != 0.
GO_MOD=apps/scanner/go.mod
cp "$GO_MOD" "$GO_MOD.bak"
# Ajoute une ligne require fictive dans le bloc principal.
awk '
  /^require[[:space:]]*\(/ {
    print
    print "\tgithub.com/fake/unaudited v0.0.1"
    next
  }
  { print }
' "$GO_MOD.bak" > "$GO_MOD"
assert_lint "fake unaudited dep -> exit != 0" 1
mv "$GO_MOD.bak" "$GO_MOD"

# 3. Retour à l'état propre.
assert_lint "post-cleanup -> exit 0" 0

if (( fail != 0 )); then
  echo "check_scanner_deps_licenses tests: KO" >&2
  exit 1
fi

echo "check_scanner_deps_licenses tests: all green"
