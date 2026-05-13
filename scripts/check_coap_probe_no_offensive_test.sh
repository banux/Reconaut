#!/usr/bin/env bash
# scripts/check_coap_probe_no_offensive_test.sh — tests du linter
# anti-offensif CoAP.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_coap_probe_no_offensive.sh > /tmp/check_coap_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_coap_out
    fail=1
  fi
}

assert_lint "current coapprobe tree -> exit 0" 0

TARGET=apps/scanner/internal/coapprobe/coapprobe.go
cp "$TARGET" "$TARGET.bak"

for pattern in "var POST = \"x\"" "var PUT = \"x\"" "var DELETE = \"x\"" "var Observe = \"x\"" "var x = \"224.0.1.187\""; do
  cat >> "$TARGET" <<GO

func injectedForTest() {
	$pattern
}
GO
  assert_lint "'$pattern' injected -> exit != 0" 1
  cp "$TARGET.bak" "$TARGET"
done

rm "$TARGET.bak"

assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_coap_probe_no_offensive tests: KO" >&2
  exit 1
fi

echo "check_coap_probe_no_offensive tests: all green"
