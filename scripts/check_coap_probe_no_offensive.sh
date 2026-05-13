#!/usr/bin/env bash
# scripts/check_coap_probe_no_offensive.sh — garantit que le sondeur
# CoAP n'introduit JAMAIS de méthode mutante (PUT/POST/DELETE),
# d'observation persistante (Observe) ni de découverte multicast.
#
# Source de vérité :
#   openspec/changes/add-coap-probe/specs/scanning/spec.md
#     -> Requirement: CoAP Discovery Probe
#     -> Scenario: Aucune méthode mutante ni Observe (audit statique)
#
# Le sondeur s'arrête à GET /.well-known/core. Toute introduction de
# PUT/POST/DELETE (mutation côté device), Observe (subscription
# persistante), ou multicast (224.0.1.187 = all-CoAP-nodes) viole
# le contrat — Reconaut n'est PAS un outil offensif.

set -euo pipefail

cd "$(dirname "$0")/.."

target_dir="apps/scanner/internal/coapprobe"

if [[ ! -d "$target_dir" ]]; then
  echo "check_coap_probe_no_offensive: skip ($target_dir absent)" >&2
  exit 0
fi

errors=0

fail() {
  echo "coap-probe-no-offensive: $1" >&2
  errors=1
}

# Patterns interdits dans le code de prod (hors *_test.go).
# `POST`, `PUT`, `DELETE` (méthodes mutantes CoAP).
# `Observe` (option 6 — subscription persistante).
# `multicast`, `224.0.1.187` (all-CoAP-nodes — broadcast offensif).
forbidden='\bPOST\b|\bPUT\b|\bDELETE\b|\bObserve\b|\bmulticast\b|224\.0\.1\.187'

prod_files=$(find "$target_dir" -type f -name "*.go" -not -name "*_test.go")

if [[ -n "$prod_files" ]]; then
  hits=$(grep -HnE "$forbidden" $prod_files 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*(//|/\*|\*)' \
    `# Allowlist : labels du response code (RFC 7252 §12.1)` \
    `# qui mentionnent "Bad Request", "Not Found", etc. NE` \
    `# contiennent JAMAIS POST/PUT/DELETE en tant que mots-clés.` \
    `# Allowlist explicite : la fonction isMulticastTarget` \
    `# documente l'invariant, on tolère ses mentions internes.` \
    | grep -vE 'IsMulticast|isMulticastTarget|multicast target refused' \
    || true)
  if [[ -n "$hits" ]]; then
    fail "méthode mutante / Observe / multicast détecté dans $target_dir :"
    echo "$hits" >&2
  fi
fi

if (( errors != 0 )); then
  echo "check_coap_probe_no_offensive: KO ($errors violations)" >&2
  exit 1
fi

echo "check_coap_probe_no_offensive: OK"
