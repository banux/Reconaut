#!/usr/bin/env bash
# scripts/check_stack.sh - linter de stack
#
# Source de verite : openspec/changes/add-tech-stack/tasks.md section 2.3
#
# Refuse toute violation des invariants stack figes par add-tech-stack :
#   - frontend Vue 3 uniquement (pas de React/Angular/Svelte)
#   - aucun residu Python ou Rust dans le repo
#   - aucun broker externe pour la file de jobs (Redis/RabbitMQ/NATS/Kafka)
#   - aucune colonne `tenant_id` dans les migrations Rails ou schemas Go
#     (modele tenant unique)
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

# --- frontend : Vue 3 only ----------------------------------------------------
if [[ -d apps/web ]]; then
  if find apps/web -type f \( -name "*.jsx" -o -name "*.tsx" \) 2>/dev/null | grep -q .; then
    fail "apps/web contient des fichiers .jsx ou .tsx (frontend doit etre Vue 3)"
  fi
  if [[ -f apps/web/package.json ]]; then
    if grep -qE '"(react|@angular/core|svelte|next|nuxt)"' apps/web/package.json; then
      fail "apps/web/package.json reference React/Angular/Svelte/Next/Nuxt"
    fi
  fi
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

if (( errors != 0 )); then
  echo "check_stack: KO ($errors violations)" >&2
  exit 1
fi

echo "check_stack: OK"
