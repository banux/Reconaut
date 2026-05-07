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

# --- 2. Fichier .jsx interdit ---
mkdir -p apps/web/src
touch apps/web/src/Bad.jsx
assert_lint ".jsx in apps/web -> exit != 0" 1
rm -f apps/web/src/Bad.jsx

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

# --- 8. SDK d'analytics tiers cote Vue ---
cp apps/web/package.json apps/web/package.json.bak
node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync("apps/web/package.json"));p.dependencies["mixpanel-browser"]="^2.0.0";fs.writeFileSync("apps/web/package.json", JSON.stringify(p, null, 2))'
assert_lint "mixpanel-browser in apps/web/package.json -> exit != 0" 1
mv apps/web/package.json.bak apps/web/package.json

# --- 7. Etat propre apres cleanup ---
assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_stack tests: KO" >&2
  exit 1
fi

echo "check_stack tests: all green"
