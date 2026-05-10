#!/usr/bin/env bash
# scripts/check_http_probe_no_offensive.sh — garantit que le sondeur
# HTTP reste passif (banner only) : pas de POST, pas d'auth, pas de
# path traversal, pas de payload weaponisé.
#
# Source de vérité :
#   openspec/changes/add-http-probe/specs/scanning/spec.md
#     -> Requirement: HTTP Banner and TLS Capture
#     -> Scenarios "Aucune méthode HTTP autre que GET/HEAD utilisée",
#                  "Pas d'auth header fabriqué",
#                  "Pas de payload weaponisé"
#
# Le linter scan `apps/scanner/internal/httpprobe/` (hors fichiers
# _test.go et hors commentaires) pour des patterns interdits.

set -euo pipefail

cd "$(dirname "$0")/.."

target_dir="apps/scanner/internal/httpprobe"

if [[ ! -d "$target_dir" ]]; then
  echo "check_http_probe_no_offensive: skip ($target_dir absent)" >&2
  exit 0
fi

errors=0

fail() {
  echo "http-probe-no-offensive: $1" >&2
  errors=1
}

# Fichiers de prod uniquement (exclut _test.go).
prod_files=$(find "$target_dir" -type f -name "*.go" -not -name "*_test.go")

if [[ -z "$prod_files" ]]; then
  echo "check_http_probe_no_offensive: skip (no prod files)" >&2
  exit 0
fi

# Méthodes HTTP interdites.
methods='http\.MethodPost|http\.MethodPut|http\.MethodDelete|http\.MethodPatch|http\.MethodOptions|http\.MethodTrace|http\.MethodConnect'

# Auth / Cookie headers fabriqués côté client.
auth='Authorization:|Bearer\s|Set-Cookie|^[^/]*Cookie:|tls\.Certificate\{'

# Path traversal dans des littéraux URL.
traversal='\.\./|%2[eE]%2[eE]'

# Payload weaponisés.
payload='<script|\$\{jndi:|eval\(|__proto__|<iframe'

run_check() {
  local pattern="$1"
  local label="$2"
  local hits
  hits=$(grep -HnE "$pattern" $prod_files 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*(//|/\*|\*)' \
    || true)
  if [[ -n "$hits" ]]; then
    fail "$label détecté dans le code de prod :"
    echo "$hits" >&2
  fi
}

run_check "$methods"  "Méthode HTTP autre que GET/HEAD"
run_check "$auth"     "Header d'auth ou client cert fabriqué"
run_check "$traversal" "Path traversal"
run_check "$payload"  "Payload weaponisé"

if (( errors != 0 )); then
  echo "check_http_probe_no_offensive: KO ($errors violations)" >&2
  exit 1
fi

echo "check_http_probe_no_offensive: OK"
