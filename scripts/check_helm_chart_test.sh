#!/usr/bin/env bash
# scripts/check_helm_chart_test.sh — tests du linter helm.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_helm_chart.sh > /tmp/check_helm_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_helm_out
    fail=1
  fi
}

# 1. État de base : chart livré passe le linter.
assert_lint "current chart tree -> exit 0" 0

# 2. Injection d'une erreur de templating (variable indéfinie) → exit != 0
#    SI helm est disponible. Sinon (fallback structurel), le linter
#    ne détecte pas l'erreur → ce test est skip.
if command -v helm >/dev/null 2>&1; then
  TARGET=deploy/helm/reconaut/templates/deployment-api.yaml
  cp "$TARGET" "$TARGET.bak"
  echo '{{ required "missing variable" .Values.thisDoesNotExist }}' >> "$TARGET"
  assert_lint "missing required value -> exit != 0 (helm dispo)" 1
  mv "$TARGET.bak" "$TARGET"

  # 3. Injection d'un tenant_id dans un template → exit != 0
  cp "$TARGET" "$TARGET.bak"
  sed -i 's/app.kubernetes.io\/component: api/tenant_id: "x"/' "$TARGET"
  assert_lint "tenant_id injected -> exit != 0 (helm dispo)" 1
  mv "$TARGET.bak" "$TARGET"
else
  echo "[skip] helm CLI absent — tests d'injection skippés (fallback structurel only)"
fi

# 4. État propre.
assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_helm_chart tests: KO" >&2
  exit 1
fi

echo "check_helm_chart tests: all green"
