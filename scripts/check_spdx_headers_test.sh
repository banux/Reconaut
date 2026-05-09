#!/usr/bin/env bash
# scripts/check_spdx_headers_test.sh — tests du linter SPDX.
# Cf. scripts/check_spdx_headers.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_spdx_headers.sh > /tmp/check_spdx_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_spdx_out
    fail=1
  fi
}

# --- 1. Etat de base : OK ---
assert_lint "current tree -> exit 0" 0

# --- 2. Source Ruby sans SPDX -> exit != 0 ---
mkdir -p apps/api/app/lib/_test_tmp
cat > apps/api/app/lib/_test_tmp/no_header.rb <<'RUBY'
# frozen_string_literal: true

class Foo
end
RUBY
assert_lint "Ruby file without SPDX -> exit != 0" 1
rm -rf apps/api/app/lib/_test_tmp

# --- 3. Source Go sans SPDX -> exit != 0 ---
mkdir -p apps/tui/_test_tmp
cat > apps/tui/_test_tmp/foo.go <<'GO'
package _test_tmp

func Foo() int { return 1 }
GO
assert_lint "Go file without SPDX -> exit != 0" 1
rm -rf apps/tui/_test_tmp

# --- 4. Etat propre apres cleanup ---
assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_spdx_headers tests: KO" >&2
  exit 1
fi

echo "check_spdx_headers tests: all green"
