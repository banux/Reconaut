#!/usr/bin/env bash
# scripts/check_modbus_probe_no_write_test.sh — tests du linter anti-write
# Modbus.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_modbus_probe_no_write.sh > /tmp/check_modbus_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_modbus_out
    fail=1
  fi
}

assert_lint "current modbusprobe tree -> exit 0" 0

TARGET=apps/scanner/internal/modbusprobe/modbusprobe.go
cp "$TARGET" "$TARGET.bak"

for pattern in \
  "var WriteSingleCoil = 1" \
  "var WriteMultipleRegisters = 1" \
  "var MaskWriteRegister = 1" \
  "var Diagnostics = 1" \
  "var Restart = 1" \
  "var ForceCoil = 1"; do
  cat >> "$TARGET" <<GO

func injectedForTest() {
	$pattern
	_ = $(echo "$pattern" | awk '{print $2}')
}
GO
  assert_lint "'$pattern' injected -> exit != 0" 1
  cp "$TARGET.bak" "$TARGET"
done

rm "$TARGET.bak"

assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_modbus_probe_no_write tests: KO" >&2
  exit 1
fi

echo "check_modbus_probe_no_write tests: all green"
