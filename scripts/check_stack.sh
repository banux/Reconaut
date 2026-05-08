#!/usr/bin/env bash
# scripts/check_stack.sh - linter de stack
#
# Source de verite : openspec/changes/add-tech-stack/tasks.md section 2.3
#                  + openspec/changes/init-reconaut-platform/tasks.md section 1.3
#
# Refuse toute violation des invariants stack figes par add-tech-stack :
#   - frontend Vue 3 uniquement (pas de React/Angular/Svelte)
#   - aucun residu Python ou Rust dans le repo
#   - aucun broker externe pour la file de jobs (Redis/RabbitMQ/NATS/Kafka)
#   - aucune colonne `tenant_id` dans les migrations Rails ou schemas Go
#     (modele tenant unique)
#   - aucun SDK d'analytics tiers (Mixpanel, Segment, Amplitude, PostHog,
#     Plausible server SDK, Matomo) - cf. init-reconaut-platform 1.3
#
# Iteration courante : verification simple basee sur grep + extensions de
# fichier. Sera enrichie quand les sous-apps existeront (parsing AST,
# inspection Gemfile.lock, etc.).

set -euo pipefail

cd "$(dirname "$0")/.."

errors=0

fail() {
  echo "stack-violation: $1" >&2
  errors=1
}

# --- frontend : pas de SPA, TUI Go uniquement -------------------------------
# Cf. openspec/changes/replace-web-with-tui/ : la SPA Vue a été retirée
# au profit du binaire `apps/tui/cmd/reconautctl`. Toute résurgence d'un
# framework web (Vue, React, Angular, Svelte, Solid, Next, Nuxt) est
# rejetée. Les fichiers `.vue`/`.jsx`/`.tsx`/`.svelte` n'ont plus leur
# place dans le repo.
if [[ -d apps/web ]]; then
  fail "apps/web/ a été retiré par replace-web-with-tui ; ne pas le réintroduire"
fi
if find apps -type f \( -name "*.vue" -o -name "*.jsx" -o -name "*.tsx" -o -name "*.svelte" \) 2>/dev/null | grep -q .; then
  fail "frontend-stack-violation: web frameworks not shipped in v1, use the Go TUI"
fi

# --- pas d'asset pipeline Rails (cf. replace-web-with-tui §1.3) -------------
# Reconaut ne sert pas de bundle SPA depuis Rails. Toute gem d'asset
# pipeline est interdite — le binaire TUI Go est la seule UI livrée.
if [[ -f apps/api/Gemfile ]]; then
  if grep -qiE '^\s*gem\s+["'"'"'](propshaft|importmap-rails|sprockets-rails|webpacker|jsbundling-rails|cssbundling-rails)["'"'"']' apps/api/Gemfile; then
    fail "apps/api/Gemfile reference une gem d'asset pipeline web (propshaft/importmap/sprockets/webpacker/jsbundling/cssbundling) ; Reconaut ne sert pas de SPA"
  fi
fi
if [[ -d apps/api/app/javascript ]]; then
  fail "apps/api/app/javascript/ existe ; Reconaut ne sert pas de bundle JS depuis Rails"
fi

# --- pas de Python ni de Rust ------------------------------------------------
if find . -type f \
     \( -name "*.py" -o -name "pyproject.toml" -o -name "uv.lock" -o -name "Cargo.toml" -o -name "Cargo.lock" \) \
     -not -path "./.git/*" \
     -not -path "./ralphy-spec/*" \
     2>/dev/null | grep -q .; then
  fail "fichiers Python ou Rust detectes (stack figee Ruby + Go + Vue)"
fi

# --- pas de broker externe pour la file de jobs -----------------------------
if [[ -f docker-compose.yml ]]; then
  if grep -qiE '^\s*(image|build):.*(redis|rabbitmq|nats|kafka)' docker-compose.yml; then
    if ! grep -qiE '^\s*#.*allowlist:' docker-compose.yml; then
      fail "docker-compose.yml reference un broker externe (redis/rabbitmq/nats/kafka)"
    fi
  fi
fi

if [[ -f apps/api/Gemfile.lock ]]; then
  if grep -qiE '^\s+(sidekiq|resque|bunny|kafka-ruby)\s' apps/api/Gemfile.lock; then
    fail "apps/api/Gemfile.lock reference un broker externe (sidekiq/resque/bunny/kafka-ruby)"
  fi
fi

# --- modele tenant unique ----------------------------------------------------
if [[ -d apps/api/db/migrate ]]; then
  if grep -RinE 'tenant_id' apps/api/db/migrate 2>/dev/null | grep -q .; then
    fail "migration Rails reference tenant_id (modele tenant unique)"
  fi
fi

if [[ -d apps/scanner ]]; then
  if grep -RinE 'tenant_?id' apps/scanner --include='*.go' 2>/dev/null | grep -q .; then
    fail "code Go reference tenant_id (modele tenant unique)"
  fi
fi

# --- pas de SDK d'analytics tiers --------------------------------------------
# Liste des patterns d'analytics interdits, cf. init-reconaut-platform 1.3.
analytics_pattern='(mixpanel|segment-analytics|@?segment/analytics|amplitude|posthog|plausible-tracker|matomo-tracker)'

if [[ -f apps/api/Gemfile ]]; then
  if grep -iE "gem\s+[\"']${analytics_pattern}" apps/api/Gemfile >/dev/null 2>&1; then
    fail "apps/api/Gemfile reference un SDK d'analytics tiers (mixpanel/segment/amplitude/posthog/plausible/matomo)"
  fi
fi

if [[ -f apps/web/package.json ]]; then
  # Match "mixpanel", "mixpanel-browser", "@segment/analytics", etc.
  if grep -iE "\"[^\"]*${analytics_pattern}[^\"]*\"\\s*:" apps/web/package.json >/dev/null 2>&1; then
    fail "apps/web/package.json reference un SDK d'analytics tiers"
  fi
fi

if [[ -d apps/scanner ]] && [[ -f apps/scanner/go.mod ]]; then
  if grep -iE "(mixpanel|segmentio/analytics|amplitude|posthog|plausible|matomo)" apps/scanner/go.mod >/dev/null 2>&1; then
    fail "apps/scanner/go.mod reference un SDK d'analytics tiers"
  fi
fi

# --- mono-user : pas d'OIDC, pas de nouveau rôle multi-utilisateur --------
# Cf. openspec/changes/single-user-only/ : Reconaut est mono-user en v1.
# Pas de gem OIDC (omniauth-oidc, openid_connect, doorkeeper-openid_connect).
# Pas de réintroduction d'un système de rôles dans le code applicatif.
if [[ -f apps/api/Gemfile ]]; then
  if grep -iE '^\s*gem\s+["'"'"'](omniauth-oidc|openid_connect|doorkeeper-openid_connect|omniauth)["'"'"']' apps/api/Gemfile >/dev/null 2>&1; then
    fail "apps/api/Gemfile reintroduit une dependance OIDC ; Reconaut est mono-user (cf. single-user-only)"
  fi
fi
if [[ -d apps/api/app/controllers ]]; then
  if grep -RIlE "VALID_ROLES|READ_ROLES|WRITE_ROLES|AUTHORIZED_ROLES|RoleResolver" apps/api/app/ apps/api/lib/ 2>/dev/null | grep -q .; then
    fail "code applicatif reintroduit une constante de roles (VALID_ROLES / READ_ROLES / etc.) ; Reconaut est mono-user"
  fi
fi

# --- positionnement narratif : pas de mention MSSP -------------------------
# cf. openspec/changes/reposition-as-agent-knowledge-base/ qui retire
# l'objectif MSSP du perimetre produit. Allowlist : le change qui retire
# MSSP a le droit de le mentionner pour expliquer ce qui disparait.
mssp_allowlist=(
  "openspec/changes/reposition-as-agent-knowledge-base/"
)

# Cherche MSSP dans les zones narratives.
mssp_hits=$(grep -RnIE 'MSSP' \
  openspec/ docs/ README.md 2>/dev/null \
  | grep -v "$(printf -- '-e %s ' "${mssp_allowlist[@]}" | sed 's| -e | -e |g')" || true)

# Filtre maison : retire les lignes provenant d'un fichier sous l'allowlist.
filtered=""
if [[ -n "$mssp_hits" ]]; then
  while IFS= read -r line; do
    skip=0
    for allow in "${mssp_allowlist[@]}"; do
      if [[ "$line" == "$allow"* ]]; then
        skip=1
        break
      fi
    done
    [[ $skip -eq 0 ]] && filtered+="$line"$'\n'
  done <<< "$mssp_hits"
fi

if [[ -n "$filtered" ]]; then
  fail "MSSP mentionne dans la doc / les specs hors de la zone autorisee :"
  echo "$filtered" >&2
fi

if (( errors != 0 )); then
  echo "check_stack: KO ($errors violations)" >&2
  exit 1
fi

echo "check_stack: OK"
