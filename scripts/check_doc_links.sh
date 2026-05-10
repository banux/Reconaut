#!/usr/bin/env bash
# scripts/check_doc_links.sh — vérifie que les liens relatifs dans
# `docs/**/*.md` pointent vers des fichiers existants.
#
# Cf. openspec/changes/add-doc-site/specs/open-source-governance/spec.md
#   -> Requirement: Public Documentation Site (linter de cohérence)
#
# Le linter scan les fichiers Markdown sous `docs/`, extrait les liens
# `[label](relative/path.md)` et `[label](relative/path.md#anchor)`,
# et vérifie que chaque cible existe sur le filesystem.
#
# Liens ignorés :
#   - URLs absolues (https://, http://, mailto:, tel:)
#   - Ancres internes (#section)
#   - Liens vers des fichiers HORS de docs/ (réécrits en URL GitHub
#     par le change `add-doc-site` ; détectés par le préfixe github.com)
#
# Limitations :
#   - ne vérifie pas que les ancres `#section` existent dans le fichier
#     cible (mkdocs build --strict s'en charge plus rigoureusement).
#   - parse simple par regex ; n'extrait pas les liens dans les blocs
#     de code (filtre approximatif sur `^[[:space:]]*\`\`\``).

set -euo pipefail

cd "$(dirname "$0")/.."

errors=0

fail() {
  echo "doc-links: $1" >&2
  errors=1
}

if [[ ! -d docs ]]; then
  echo "check_doc_links: skip (docs/ absent)" >&2
  exit 0
fi

# Pour chaque fichier .md sous docs/, extrait les liens relatifs.
while IFS= read -r -d '' f; do
  in_code=0
  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    if [[ "$line" =~ ^[[:space:]]*\`\`\` ]]; then
      in_code=$((1 - in_code))
      continue
    fi
    [[ $in_code -eq 1 ]] && continue

    # Extrait tous les `](path)` de la ligne. Tolère plusieurs liens
    # par ligne en bouclant sur les matches (sed n'est pas suffisant ;
    # on fait du grep -oE).
    matches=$(echo "$line" | grep -oE '\]\([^)#]+\)' || true)
    [[ -z "$matches" ]] && continue

    while IFS= read -r m; do
      # Strip leading `]( ` and trailing `)`
      target=${m#](}
      target=${target%)}
      # Ignore les URLs absolues
      [[ "$target" =~ ^https?:// ]] && continue
      [[ "$target" =~ ^mailto: ]] && continue
      [[ "$target" =~ ^tel: ]] && continue
      # Ignore les ancres pures
      [[ "$target" =~ ^# ]] && continue
      # Strip query/anchor
      target_path=${target%%#*}
      target_path=${target_path%%\?*}
      [[ -z "$target_path" ]] && continue

      # Résoud le chemin relatif au fichier source
      src_dir=$(dirname "$f")
      resolved="$src_dir/$target_path"
      # Normalise (collapse les ../)
      resolved=$(realpath -m --relative-to=. "$resolved" 2>/dev/null || echo "$resolved")

      if [[ ! -e "$resolved" ]]; then
        fail "${f}:${lineno} : lien cassé '${target}' → cible introuvable (${resolved})"
      fi
    done <<< "$matches"
  done < "$f"
done < <(find docs -type f -name "*.md" -print0)

if (( errors != 0 )); then
  echo "check_doc_links: KO ($errors lien(s) cassé(s))" >&2
  exit 1
fi

echo "check_doc_links: OK"
