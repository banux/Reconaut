#!/usr/bin/env bash
# scripts/check_mqtt_probe_no_auth_test.sh — tests du linter anti-auth
# du sondeur MQTT.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_mqtt_probe_no_auth.sh > /tmp/check_mqtt_probe_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_mqtt_probe_out
    fail=1
  fi
}

assert_lint "current mqttprobe tree -> exit 0" 0

TARGET=apps/scanner/internal/mqttprobe/mqttprobe.go
cp "$TARGET" "$TARGET.bak"

for pattern in "var password = \"x\"" "var username = \"u\"" "var WillTopic = \"t\"" "_ = Publish(nil)" "_ = Subscribe(nil)"; do
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
  echo "check_mqtt_probe_no_auth tests: KO" >&2
  exit 1
fi

echo "check_mqtt_probe_no_auth tests: all green"
