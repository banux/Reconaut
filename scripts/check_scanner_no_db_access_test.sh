#!/usr/bin/env bash
# scripts/check_scanner_no_db_access_test.sh — tests du linter anti-DB
# côté workers.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_scanner_no_db_access.sh > /tmp/check_scanner_no_db_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_scanner_no_db_out
    fail=1
  fi
}

# 1. État de base : OK.
assert_lint "current scanner tree -> exit 0" 0

# 2. Injection d'un import database/sql dans un fichier prod -> KO.
TARGET=apps/scanner/internal/runtime/runtime.go
cp "$TARGET" "$TARGET.bak"
cat > /tmp/inject.go <<'GO'
package runtime
import _ "database/sql"
GO
cat /tmp/inject.go >> "$TARGET"
assert_lint "import database/sql injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 3. Injection de RECONAUT_DATABASE_URL -> KO.
cp "$TARGET" "$TARGET.bak"
cat >> "$TARGET" <<'GO'

var x = "RECONAUT_DATABASE_URL"
GO
assert_lint "RECONAUT_DATABASE_URL reference injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 4. Injection d'un import pgx -> KO.
cp "$TARGET" "$TARGET.bak"
cat >> "$TARGET" <<'GO'

import _ "github.com/jackc/pgx/v5/stdlib"
GO
assert_lint "github.com/jackc/pgx injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 5. État propre.
assert_lint "post-cleanup -> exit 0" 0

if (( fail != 0 )); then
  echo "check_scanner_no_db_access tests: KO" >&2
  exit 1
fi

echo "check_scanner_no_db_access tests: all green"
