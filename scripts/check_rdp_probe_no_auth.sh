#!/usr/bin/env bash
# scripts/check_rdp_probe_no_auth.sh — garantit que le sondeur RDP
# n'introduit JAMAIS de méthode d'authentification.
#
# Source de vérité :
#   openspec/changes/add-rdp-probe/specs/scanning/spec.md
#     -> Requirement: RDP Banner and TLS Capture
#     -> Scenario: Aucune authentification jamais tentée (audit statique)
#
# Le sondeur capture la version protocolaire, les security flags du
# RDP Negotiation Response, et optionnellement le cert TLS quand
# PROTOCOL_SSL est annoncé. Toute introduction d'un mécanisme d'auth
# (password, credential, NTLM, Kerberos, CredSSP, hash NT, etc.)
# viole le contrat — Reconaut n'est PAS un outil de bruteforce.
#
# Les commentaires en début de fichier qui DOCUMENTENT cette
# interdiction (ex. "// no password ever sent") sont autorisés via
# une allowlist sur les lignes commentaire.

set -euo pipefail

cd "$(dirname "$0")/.."

target_dir="apps/scanner/internal/rdpprobe"

if [[ ! -d "$target_dir" ]]; then
  echo "check_rdp_probe_no_auth: skip ($target_dir absent)" >&2
  exit 0
fi

errors=0

fail() {
  echo "rdp-probe-no-auth: $1" >&2
  errors=1
}

# Patterns interdits, case-insensitive. On vise les marqueurs d'auth
# RDP-spécifiques.
#
# `\bdomain\b` matcherait des contextes légitimes (DNS domain en
# commentaire) — on l'omet et on s'appuie sur les autres patterns
# pour détecter une vraie tentative d'auth (NTLM, kerberos, CredSSP,
# username, password sont sans ambiguïté).
forbidden='password|credential|username|ntlm|kerberos|credssp|passwordcallback|gokrb5|ntlmssp'

prod_files=$(find "$target_dir" -type f -name "*.go" -not -name "*_test.go")

if [[ -n "$prod_files" ]]; then
  # `-iH` : insensible à la casse + préfixe par filename.
  # On filtre out les lignes commentaire pure (`//...`, `/*...`,
  # `*...`) ET les lignes qui mentionnent ces termes uniquement
  # dans le contexte "interdit / forbidden / jamais / never" (auto-
  # documentation de la règle).
  hits=$(grep -iHnE "$forbidden" $prod_files 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*(//|/\*|\*)' \
    || true)
  if [[ -n "$hits" ]]; then
    fail "construction d'authentification RDP détectée dans le code de prod :"
    echo "$hits" >&2
  fi
fi

if (( errors != 0 )); then
  echo "check_rdp_probe_no_auth: KO ($errors violations)" >&2
  exit 1
fi

echo "check_rdp_probe_no_auth: OK"
