#!/usr/bin/env bash
# scripts/check_scanner_deps_licenses.sh — audit minimal des licences
# des dépendances Go du worker (apps/scanner).
#
# Source de vérité :
#   openspec/changes/add-scanner-pgx-driver/specs/scanning/spec.md
#     -> Requirement: Allowlist de licences pour pgx et go-sqlmock
#
# Stratégie : on parse `go.mod` (require + indirect) et on vérifie que
# chaque module figure dans une allowlist statique de (module ->
# licence). Toute dépendance inconnue → exit 1 + message qui liste
# explicitement le module à valider manuellement.
#
# Limitation assumée : pas de vérification en ligne de la licence
# effective (on fait confiance au mainteneur Reconaut qui a inspecté
# le module à chaque ajout). C'est volontaire — un go-licenses complet
# arrivera dans un futur change si le besoin se concrétise.

set -euo pipefail

cd "$(dirname "$0")/.."

GO_MOD="apps/scanner/go.mod"

if [[ ! -f "$GO_MOD" ]]; then
  echo "check_scanner_deps_licenses: skip ($GO_MOD absent)" >&2
  exit 0
fi

# Allowlist : <module>::<licence-spdx>. Maintenue à la main, alignée
# sur les licences acceptables pour AGPL-3.0 (MIT, Apache-2.0, BSD-2/3,
# ISC, MPL-2.0).
declare -A allowlist=(
  ["github.com/miekg/dns"]="BSD-3-Clause"
  ["github.com/jackc/pgx/v5"]="MIT"
  ["github.com/jackc/pgpassfile"]="MIT"
  ["github.com/jackc/pgservicefile"]="MIT"
  ["github.com/jackc/puddle/v2"]="MIT"
  ["github.com/DATA-DOG/go-sqlmock"]="MIT"
  ["golang.org/x/crypto"]="BSD-3-Clause"
  ["golang.org/x/mod"]="BSD-3-Clause"
  ["golang.org/x/net"]="BSD-3-Clause"
  ["golang.org/x/sync"]="BSD-3-Clause"
  ["golang.org/x/sys"]="BSD-3-Clause"
  ["golang.org/x/term"]="BSD-3-Clause"
  ["golang.org/x/text"]="BSD-3-Clause"
  ["golang.org/x/tools"]="BSD-3-Clause"
)

errors=0

# Extrait tous les modules listés dans go.mod (require ou indirect).
# Filtre les lignes de format `<module> v<version>` et leur variante
# `<module> v<version> // indirect`. On ignore les blocks require()
# wrappers et les directives go/module/replace.
mapfile -t modules < <(awk '
  /^require[[:space:]]*\(/ { in_block = 1; next }
  /^\)/                    { in_block = 0; next }
  in_block && $1 !~ /^\/\// { print $1 }
  /^require[[:space:]]+[^(]/ { print $2 }
' "$GO_MOD" | sort -u)

if (( ${#modules[@]} == 0 )); then
  echo "check_scanner_deps_licenses: aucune dépendance trouvée dans $GO_MOD" >&2
  exit 1
fi

for mod in "${modules[@]}"; do
  if [[ -z "${allowlist[$mod]+x}" ]]; then
    echo "scanner-deps-licenses: dépendance inconnue dans l'allowlist : '$mod'" >&2
    echo "  -> Inspecte la licence amont et ajoute-la dans scripts/check_scanner_deps_licenses.sh" >&2
    errors=1
  fi
done

if (( errors != 0 )); then
  echo "check_scanner_deps_licenses: KO ($errors dépendances non auditées)" >&2
  exit 1
fi

echo "check_scanner_deps_licenses: OK (${#modules[@]} modules audités)"
