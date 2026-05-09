#!/usr/bin/env bash
# scripts/add_spdx_headers.sh — utilitaire one-shot d'ajout des
# entêtes SPDX-License-Identifier sur les sources Ruby et Go.
#
# Cf. openspec/changes/init-reconaut-platform/tasks.md §1.1.
#
# Idempotent : skip toute source qui contient déjà la directive
# `SPDX-License-Identifier`. Pour Ruby, l'entête est inséré
# immédiatement après `# frozen_string_literal: true` (s'il existe)
# ou au tout début du fichier. Pour Go, l'entête est la première
# ligne, immédiatement avant le commentaire de package ou la
# déclaration `package`.

set -euo pipefail

cd "$(dirname "$0")/.."

LICENSE="AGPL-3.0-only"
RUBY_HEADER="# SPDX-License-Identifier: ${LICENSE}"
GO_HEADER="// SPDX-License-Identifier: ${LICENSE}"

added=0
skipped=0

process_ruby() {
  local f="$1"
  if grep -q "SPDX-License-Identifier" "$f"; then
    skipped=$((skipped + 1))
    return
  fi
  if head -1 "$f" | grep -q "^# frozen_string_literal: true"; then
    sed -i "1a ${RUBY_HEADER}" "$f"
  else
    sed -i "1i ${RUBY_HEADER}" "$f"
  fi
  added=$((added + 1))
}

process_go() {
  local f="$1"
  if grep -q "SPDX-License-Identifier" "$f"; then
    skipped=$((skipped + 1))
    return
  fi
  sed -i "1i ${GO_HEADER}" "$f"
  added=$((added + 1))
}

while IFS= read -r f; do
  process_ruby "$f"
done < <(find apps/api/app apps/api/lib apps/api/db/migrate apps/api/config -name "*.rb" -type f 2>/dev/null)

while IFS= read -r f; do
  process_go "$f"
done < <(find apps/scanner apps/tui -name "*.go" -type f 2>/dev/null)

echo "SPDX headers : ${added} ajoutés, ${skipped} déjà présents (skip)"
