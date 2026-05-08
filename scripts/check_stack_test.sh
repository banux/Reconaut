#!/usr/bin/env bash
# scripts/check_stack_test.sh - tests automatises du linter de stack.
#
# Source de verite : openspec/changes/add-tech-stack/tasks.md section 2.3.
# Materialise les cas negatifs cites dans le test plan :
#   - apps/web/src/Bad.jsx -> exit != 0
#   - migration Rails avec tenant_id -> exit != 0
#   - service redis dans docker-compose.yml -> exit != 0
#   - fichier .py a la racine -> exit != 0
# Et un cas positif : projet propre -> exit 0.

set -euo pipefail

cd "$(dirname "$0")/.."

linter="$(pwd)/scripts/check_stack.sh"
fail=0

assert_lint() {
  local label=$1
  local expected_exit=$2
  shift 2

  local actual_exit=0
  bash "$linter" >/dev/null 2>&1 || actual_exit=$?

  if [[ "$actual_exit" -ne "$expected_exit" ]]; then
    echo "[FAIL] $label: expected exit=$expected_exit got $actual_exit" >&2
    fail=1
  else
    echo "[ok]   $label"
  fi
}

# --- 1. Etat propre : doit passer ---
assert_lint "clean tree -> exit 0" 0

# --- 2. Fichier .vue/.jsx/.svelte interdit n'importe où ---
# (Cf. replace-web-with-tui §1.2 : pas de SPA, TUI Go uniquement)
touch apps/api/Bad.vue
assert_lint ".vue file anywhere -> exit != 0" 1
rm -f apps/api/Bad.vue

mkdir -p apps/scratch && touch apps/scratch/Bad.svelte
assert_lint ".svelte file anywhere -> exit != 0" 1
rm -rf apps/scratch

# Réintroduction d'apps/web/ -> rejetée
mkdir -p apps/web && touch apps/web/index.html
assert_lint "apps/web/ reintroduced -> exit != 0" 1
rm -rf apps/web

# --- 3. tenant_id dans une migration Rails ---
mkdir -p apps/api/db/migrate
cat > apps/api/db/migrate/99999999999999_add_tenant_id.rb <<'RUBY'
class AddTenantId < ActiveRecord::Migration[8.1]
  def change
    add_column :hosts, :tenant_id, :uuid
  end
end
RUBY
assert_lint "migration with tenant_id -> exit != 0" 1
rm -f apps/api/db/migrate/99999999999999_add_tenant_id.rb

# --- 4. Service redis declare comme broker dans docker-compose.yml ---
cp docker-compose.yml docker-compose.yml.bak
cat >> docker-compose.yml <<'YAML'
  redis:
    image: redis:7
YAML
assert_lint "redis broker in compose -> exit != 0" 1
mv docker-compose.yml.bak docker-compose.yml

# --- 5. Fichier Python a la racine ---
echo "print('hi')" > rogue.py
assert_lint "rogue .py file -> exit != 0" 1
rm -f rogue.py

# --- 6. Fichier Cargo.toml (residu Rust) ---
echo '[package]' > Cargo.toml
assert_lint "rogue Cargo.toml -> exit != 0" 1
rm -f Cargo.toml

# --- 7. SDK d'analytics tiers cote Rails ---
cp apps/api/Gemfile apps/api/Gemfile.bak
echo 'gem "posthog-ruby"' >> apps/api/Gemfile
assert_lint "posthog gem in apps/api/Gemfile -> exit != 0" 1
mv apps/api/Gemfile.bak apps/api/Gemfile

# --- 8. Asset pipeline Rails interdit (cf. replace-web-with-tui §1.3) ---
cp apps/api/Gemfile apps/api/Gemfile.bak
echo 'gem "propshaft"' >> apps/api/Gemfile
assert_lint "propshaft gem in apps/api/Gemfile -> exit != 0" 1
mv apps/api/Gemfile.bak apps/api/Gemfile

# Répertoire app/javascript dans Rails -> rejeté
mkdir -p apps/api/app/javascript
assert_lint "apps/api/app/javascript reintroduced -> exit != 0" 1
rm -rf apps/api/app/javascript

# --- 9. Mention MSSP dans le README -> exit != 0 ---
cp README.md README.md.bak
echo "Reconaut convient aussi aux MSSP qui veulent..." >> README.md
assert_lint "MSSP mention in README -> exit != 0" 1
mv README.md.bak README.md

# --- 10. Mention MSSP dans une doc -> exit != 0 ---
mkdir -p docs/_test_tmp
echo "Pour les MSSP qui ..." > docs/_test_tmp/rogue.md
assert_lint "MSSP mention in docs -> exit != 0" 1
rm -rf docs/_test_tmp

# --- 11. Réintroduction d'une dépendance OIDC -> exit != 0 (mono-user) ---
cp apps/api/Gemfile apps/api/Gemfile.bak
echo 'gem "omniauth-oidc"' >> apps/api/Gemfile
assert_lint "omniauth-oidc gem in apps/api/Gemfile -> exit != 0 (mono-user)" 1
mv apps/api/Gemfile.bak apps/api/Gemfile

# --- 12. Réintroduction d'une constante de roles -> exit != 0 ---
mkdir -p apps/api/app/lib/_test_tmp
cat > apps/api/app/lib/_test_tmp/roles.rb <<'RUBY'
module Foo
  VALID_ROLES = %i[viewer admin].freeze
end
RUBY
assert_lint "VALID_ROLES constant reintroduced -> exit != 0" 1
rm -rf apps/api/app/lib/_test_tmp

# --- Etat propre apres cleanup ---
assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_stack tests: KO" >&2
  exit 1
fi

echo "check_stack tests: all green"
