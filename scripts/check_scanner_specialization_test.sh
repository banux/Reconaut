#!/usr/bin/env bash
# scripts/check_scanner_specialization_test.sh — tests du linter
# spécialisation des binaires scanner-<kind>.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_scanner_specialization.sh > /tmp/check_scanner_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_scanner_out
    fail=1
  fi
}

# 1. État de base : OK (les 5 binaires existent).
assert_lint "current scanner cmd tree -> exit 0" 0

# 2. Suppression d'un binaire requis -> exit != 0.
TARGET=apps/scanner/cmd/scanner-tcp_probe/main.go
mv "$TARGET" "$TARGET.bak"
assert_lint "scanner-tcp_probe absent -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 3. Import croisé : injecter "tls_capture" dans scanner-tcp_probe.
TARGET=apps/scanner/cmd/scanner-tcp_probe/main.go
cp "$TARGET" "$TARGET.bak"
sed -i.tmp 's|"tcp_probe"|"tcp_probe" + "" + "tls_capture"|' "$TARGET"
rm -f "$TARGET.tmp"
assert_lint "import croisé tls_capture in scanner-tcp_probe -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 4. État propre après cleanup.
assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_scanner_specialization tests: KO" >&2
  exit 1
fi

echo "check_scanner_specialization tests: all green"
