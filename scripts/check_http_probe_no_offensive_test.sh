#!/usr/bin/env bash
# scripts/check_http_probe_no_offensive_test.sh — tests du linter
# anti-offensif HTTP.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_http_probe_no_offensive.sh > /tmp/check_http_probe_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_http_probe_out
    fail=1
  fi
}

TARGET=apps/scanner/internal/httpprobe/httpprobe.go

# 1. État de base : OK.
assert_lint "current httpprobe tree -> exit 0" 0

# 2. Injection d'un POST → exit != 0.
cp "$TARGET" "$TARGET.bak"
echo 'var _ = http.MethodPost' >> "$TARGET"
assert_lint "http.MethodPost injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 3. Injection d'un Authorization Bearer → exit != 0.
cp "$TARGET" "$TARGET.bak"
echo 'const _h = "Authorization: Bearer abc"' >> "$TARGET"
assert_lint "Authorization Bearer injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 4. Injection d'un path traversal → exit != 0.
cp "$TARGET" "$TARGET.bak"
echo 'const _p = "/foo/../etc/passwd"' >> "$TARGET"
assert_lint "path traversal injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 5. Injection d'un payload Log4Shell → exit != 0.
cp "$TARGET" "$TARGET.bak"
echo 'const _q = "${jndi:ldap://x}"' >> "$TARGET"
assert_lint "Log4Shell payload injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 6. Mention dans commentaire est tolérée.
cp "$TARGET" "$TARGET.bak"
echo '// Pas de http.MethodPost dans le sondeur (interdit par check_http_probe_no_offensive).' >> "$TARGET"
assert_lint "MethodPost in comment -> exit 0" 0
mv "$TARGET.bak" "$TARGET"

# 7. Mention dans _test.go est tolérée.
TEST_FILE=apps/scanner/internal/httpprobe/httpprobe_test.go
cp "$TEST_FILE" "$TEST_FILE.bak"
echo 'var _ = http.MethodPost' >> "$TEST_FILE"
assert_lint "MethodPost in _test.go -> exit 0" 0
mv "$TEST_FILE.bak" "$TEST_FILE"

# 8. État propre.
assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_http_probe_no_offensive tests: KO" >&2
  exit 1
fi

echo "check_http_probe_no_offensive tests: all green"
