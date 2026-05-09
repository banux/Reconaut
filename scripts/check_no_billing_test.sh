#!/usr/bin/env bash
# scripts/check_no_billing_test.sh — tests du linter no-billing.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_no_billing.sh > /tmp/check_no_billing_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_no_billing_out
    fail=1
  fi
}

# 1. État de base : OK.
assert_lint "current tree -> exit 0" 0

# 2. Injection d'une gem stripe dans Gemfile -> exit != 0.
TARGET=apps/api/Gemfile
cp "$TARGET" "$TARGET.bak"
echo 'gem "stripe", "~> 12.0"' >> "$TARGET"
assert_lint "stripe gem in Gemfile -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 3. Injection d'une gem chargebee dans Gemfile -> exit != 0.
cp "$TARGET" "$TARGET.bak"
echo "gem 'chargebee'" >> "$TARGET"
assert_lint "chargebee gem in Gemfile -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 4. Injection d'un import Go stripe dans go.mod -> exit != 0.
GOMOD=apps/scanner/go.mod
cp "$GOMOD" "$GOMOD.bak"
echo 'require github.com/stripe/stripe-go/v76 v76.0.0' >> "$GOMOD"
assert_lint "stripe-go in go.mod -> exit != 0" 1
mv "$GOMOD.bak" "$GOMOD"

# 5. Injection d'une variable de licence dans un controller -> exit != 0.
TARGET=apps/api/app/controllers/healthz_controller.rb
if [[ -f "$TARGET" ]]; then
  cp "$TARGET" "$TARGET.bak"
  # Ajoute du code (pas un commentaire) qui référence RECONAUT_LICENSE_KEY.
  awk 'NR==1{print; print "raise unless ENV[\"RECONAUT_LICENSE_KEY\"]"; next}{print}' "$TARGET.bak" > "$TARGET"
  assert_lint "RECONAUT_LICENSE_KEY in controller -> exit != 0" 1
  mv "$TARGET.bak" "$TARGET"
fi

# 6. État propre.
assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_no_billing tests: KO" >&2
  exit 1
fi

echo "check_no_billing tests: all green"
