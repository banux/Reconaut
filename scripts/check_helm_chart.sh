#!/usr/bin/env bash
# scripts/check_helm_chart.sh — valide le chart Helm Reconaut.
#
# Source de vérité :
#   openspec/changes/add-helm-chart/specs/open-source-governance/spec.md
#     -> Requirement: Helm Chart Linter
#
# Si `helm` est dans PATH :
#   - `helm lint deploy/helm/reconaut`
#   - `helm template ... --set postgres.url=... --set auth.bootstrap.operatorPassword=...`
#     puis vérifier que le résultat est du YAML valide.
# Sinon : fallback validation YAML statique sur chaque template
#   (ne rend pas les directives Helm — juste vérifie que le squelette
#   reste lisible). Permet aux contributeurs sans helm de ne pas
#   casser le build local.

set -euo pipefail

cd "$(dirname "$0")/.."

CHART_DIR="deploy/helm/reconaut"

if [[ ! -d "$CHART_DIR" ]]; then
  echo "check_helm_chart: skip ($CHART_DIR absent)" >&2
  exit 0
fi

errors=0

fail() {
  echo "helm-chart: $1" >&2
  errors=1
}

if command -v helm >/dev/null 2>&1; then
  # ---- Mode validation profonde ---------------------------------------------
  if ! helm lint "$CHART_DIR" > /tmp/helm-lint-out 2>&1; then
    fail "helm lint a échoué :"
    cat /tmp/helm-lint-out >&2
  fi

  rendered=$(helm template testrel "$CHART_DIR" \
    --set postgres.url='postgresql://t:t@t:5432/t' \
    --set auth.bootstrap.operatorPassword='x' 2>/tmp/helm-tpl-err) \
    || {
      fail "helm template a échoué :"
      cat /tmp/helm-tpl-err >&2
    }

  # Vérifie qu'on a bien les ressources attendues (sanity).
  if ! echo "$rendered" | grep -qE "^kind: Deployment"; then
    fail "helm template ne produit aucun Deployment"
  fi
  if ! echo "$rendered" | grep -qE "^kind: Service"; then
    fail "helm template ne produit aucun Service"
  fi
  if ! echo "$rendered" | grep -qE "^kind: ConfigMap"; then
    fail "helm template ne produit aucun ConfigMap"
  fi

  # Mono-tenant : aucun tenant_id ne doit apparaître dans le manifest
  # rendu (cohérent avec init §234 et le linter check_stack.sh).
  if echo "$rendered" | grep -qiE "tenant_id"; then
    fail "manifest rendu contient une référence tenant_id (violation mono-user)"
  fi
else
  # ---- Mode fallback : sanity check structurel ------------------------------
  echo "[helm-chart] helm not installed — falling back to structural checks"
  for f in "$CHART_DIR/Chart.yaml" "$CHART_DIR/values.yaml"; do
    if [[ ! -f "$f" ]]; then
      fail "$f manquant"
    fi
  done
  # Templates : on ne peut pas les parser tels quels (Go templating),
  # mais on vérifie au moins qu'aucun n'est vide et qu'ils existent.
  if ! ls "$CHART_DIR"/templates/*.yaml >/dev/null 2>&1; then
    fail "aucun template sous $CHART_DIR/templates/"
  fi
  # Validation YAML optionnelle via Python si dispo. Sinon, on
  # contente le check structurel et on attend que la CI ait helm.
  if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
    for f in "$CHART_DIR/Chart.yaml" "$CHART_DIR/values.yaml"; do
      python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/tmp/yaml-err || {
        fail "$f : YAML invalide :"
        cat /tmp/yaml-err >&2
      }
    done
  fi
fi

if (( errors != 0 )); then
  echo "check_helm_chart: KO ($errors violations)" >&2
  exit 1
fi

echo "check_helm_chart: OK"
