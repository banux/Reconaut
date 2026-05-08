#!/usr/bin/env bash
# scripts/check_scanner_specialization.sh — vérifie que chaque
# binaire `scanner-<kind>` n'importe que les sondeurs / packages
# autorisés pour son protocole.
#
# Source de vérité :
#   openspec/changes/replace-web-with-tui/specs/architecture/spec.md
#     -> Requirement: Specialized Scan Workers per scan_kind
#   openspec/changes/replace-web-with-tui/tasks.md §3.3
#
# Pour la v1, aucun sondeur de protocole n'est encore livré (ils
# arriveront avec les changes `scan-engine-<protocol>`). Le linter
# vérifie donc :
#   - chaque scan_kind du contrat ScanJobV1 a son binaire main.go
#     sous apps/scanner/cmd/scanner-<kind>/,
#   - aucun import croisé (un binaire qui importerait une lib
#     spécifique à un autre kind violerait la spécialisation).
#
# Quand un scan-engine-<protocol> sera livré, ce script s'enrichira
# d'une allowlist du type :
#   scanner-tcp_probe : [net, syscall]
#   scanner-tls_capture : [crypto/tls, net]
#   scanner-http_banner : [net/http]
#   scanner-subdomain_enum : [net]
#   scanner-service_fingerprint : [...]

set -euo pipefail

cd "$(dirname "$0")/.."

errors=0

fail() {
  echo "scanner-specialization: $1" >&2
  errors=1
}

if [[ ! -d apps/scanner/cmd ]]; then
  echo "check_scanner_specialization: skip (apps/scanner/cmd absent)" >&2
  exit 0
fi

EXPECTED_KINDS=(tcp_probe tls_capture http_banner subdomain_enum service_fingerprint)

for kind in "${EXPECTED_KINDS[@]}"; do
  main="apps/scanner/cmd/scanner-${kind}/main.go"
  if [[ ! -f "$main" ]]; then
    fail "binaire scanner-${kind} attendu mais absent (${main})"
    continue
  fi
  # Le main.go DOIT contenir la string "scan_kind" correspondante
  # (heuristique : on vérifie `ScanKind: "<kind>"` ou `"<kind>"`
  # explicitement présent).
  if ! grep -qE "\"${kind}\"" "$main"; then
    fail "scanner-${kind}/main.go ne référence pas son scan_kind \"${kind}\" en littéral"
  fi
done

# Vérifie qu'aucun binaire scanner-<kind> n'importe le runtime d'un
# autre kind. Comme tous délèguent à internal/runtime avec un kind
# explicite en argument, on s'assure simplement qu'aucun main.go ne
# nomme deux kinds simultanément.
for kind in "${EXPECTED_KINDS[@]}"; do
  main="apps/scanner/cmd/scanner-${kind}/main.go"
  [[ -f "$main" ]] || continue
  for other in "${EXPECTED_KINDS[@]}"; do
    [[ "$kind" == "$other" ]] && continue
    if grep -qE "\"${other}\"" "$main"; then
      fail "scanner-${kind} référence le scan_kind \"${other}\" — import croisé interdit"
    fi
  done
done

if (( errors != 0 )); then
  echo "check_scanner_specialization: KO ($errors violations)" >&2
  exit 1
fi

echo "check_scanner_specialization: OK"
