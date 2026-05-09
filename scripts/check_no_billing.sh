#!/usr/bin/env bash
# scripts/check_no_billing.sh — refuse tout import de SDK de
# facturation et tout chemin de code conditionné par une variable de
# licence commerciale.
#
# Source de vérité :
#   openspec/changes/init-reconaut-platform/tasks.md §8.4
#
# Reconaut est OSS sous AGPL-3.0. Le projet ne fournit JAMAIS un
# build "pro" gated par une clé de licence ; pas de hook Stripe /
# Chargebee / Paddle ; pas de fork-points conditionnels.
# Cf. openspec/project.md (Modèle économique : pas de feature gating
# dans le tronc).
#
# Périmètre vérifié :
#   - Gemfile, Gemfile.lock : pas de gem `stripe`, `chargebee`,
#     `paddle`, `lago`, `recurly`, `braintree`, `stripe-ruby-mock`.
#   - apps/web/package.json : pas de package npm `@stripe/*`,
#     `chargebee`, `@paddle/*`, etc.
#   - apps/scanner/go.mod : pas d'import `github.com/stripe/*`,
#     `github.com/chargebee/*`, etc.
#   - apps/api/app/, apps/api/lib/, apps/scanner/, apps/tui/ :
#     pas de chemin de code gated par une variable de licence
#     commerciale (`RECONAUT_LICENSE_KEY`, `LICENSE_TIER`, etc.).
#
# Le script est conservateur : commentaires et chaînes documentation
# explicitement négatives (ex. "pas de Stripe") sont autorisés via
# allowlist.

set -euo pipefail

cd "$(dirname "$0")/.."

errors=0

fail() {
  echo "no-billing: $1" >&2
  errors=1
}

# -- 1. Gemfile / Gemfile.lock : gems de facturation -------------------------
billing_gems='stripe|chargebee|paddle-billing|paddle-rb|recurly|braintree|lago-ruby'

if [[ -f apps/api/Gemfile ]]; then
  if grep -iE "^\s*gem\s+[\"'](${billing_gems})[\"']" apps/api/Gemfile >/dev/null 2>&1; then
    fail "apps/api/Gemfile reference une gem de facturation (${billing_gems})"
  fi
fi

if [[ -f apps/api/Gemfile.lock ]]; then
  # Match les lignes de spec « stripe (8.1.0) » dans la section
  # GEM/specs/PATH. Pas de quotes, format Bundler.
  if grep -iE "^\s+(${billing_gems})\s+\([0-9]" apps/api/Gemfile.lock >/dev/null 2>&1; then
    fail "apps/api/Gemfile.lock reference une gem de facturation"
  fi
fi

# -- 2. apps/web/package.json : packages npm de facturation ------------------
billing_npm='@stripe/|stripe-js|chargebee|@paddle/|paddle-sdk|@recurly/|braintree-web'

if [[ -f apps/web/package.json ]]; then
  if grep -iE "\"[^\"]*(${billing_npm})[^\"]*\"" apps/web/package.json >/dev/null 2>&1; then
    fail "apps/web/package.json reference un package de facturation"
  fi
fi

# -- 3. apps/scanner/go.mod : imports Go de facturation ----------------------
billing_go='github\.com/stripe/|github\.com/chargebee/|github\.com/PaddleHQ/|github\.com/recurly/|github\.com/braintree/'

if [[ -f apps/scanner/go.mod ]]; then
  if grep -iE "(${billing_go})" apps/scanner/go.mod >/dev/null 2>&1; then
    fail "apps/scanner/go.mod reference un module Go de facturation"
  fi
fi

# -- 4. Variables de licence commerciale dans le code applicatif -------------
# Patterns interdits : RECONAUT_LICENSE_KEY, LICENSE_TIER, FEATURE_GATE_*,
# RECONAUT_PRO_*, RECONAUT_ENTERPRISE_*. Les conditionner produirait un
# fork-point gated.
license_pattern='RECONAUT_LICENSE_KEY|LICENSE_TIER|FEATURE_GATE_|RECONAUT_PRO_|RECONAUT_ENTERPRISE_|PAID_TIER|PAYWALL'

# Scope : code applicatif (Ruby, Go, JS/TS) ; on évite les
# checks/specs et la doc qui peuvent légitimement mentionner ces
# patterns pour expliquer ce qui est interdit.
target_dirs=(apps/api/app apps/api/lib apps/scanner apps/tui)

for dir in "${target_dirs[@]}"; do
  [[ -d "$dir" ]] || continue
  hits=$(grep -RnE "$license_pattern" "$dir" 2>/dev/null \
    | grep -vE '_test\.|_spec\.|/spec/|/test/' \
    | grep -vE ':[0-9]+:[[:space:]]*(#|//|/\*|\*)' \
    || true)
  if [[ -n "$hits" ]]; then
    fail "variable de licence commerciale détectée dans $dir :"
    echo "$hits" >&2
  fi
done

if (( errors != 0 )); then
  echo "check_no_billing: KO ($errors violations)" >&2
  exit 1
fi

echo "check_no_billing: OK"
