#!/usr/bin/env bash
# scripts/check_ssh_probe_no_auth.sh — garantit que le sondeur SSH
# n'introduit JAMAIS de méthode d'authentification.
#
# Source de vérité :
#   openspec/changes/add-ssh-probe/specs/scanning/spec.md
#     -> Requirement: SSH Banner and Host-Key Probe
#     -> Scenario: Aucune authentification jamais tentée
#
# Le sondeur capture le banner et la host-key uniquement. Toute
# introduction d'une méthode d'auth (`ssh.Password`, `ssh.PublicKeys`,
# `ssh.KeyboardInteractive`, `ssh.RetryableAuthMethod`) viole le
# contrat — Reconaut n'est PAS un outil de bruteforce.
#
# Pour les FICHIERS de tests, on autorise les *callbacks serveur*
# (`PasswordCallback`, `PublicKeyCallback`, `KeyboardInteractiveCallback`)
# qui sont l'inverse exact : ils prouvent côté serveur que le client
# n'a JAMAIS atteint la phase userauth (ils font échouer le test si
# invoqués). Ils ne sont pas une auth tentée par le sondeur.

set -euo pipefail

cd "$(dirname "$0")/.."

target_dir="apps/scanner/internal/sshprobe"

if [[ ! -d "$target_dir" ]]; then
  echo "check_ssh_probe_no_auth: skip ($target_dir absent)" >&2
  exit 0
fi

errors=0

fail() {
  echo "ssh-probe-no-auth: $1" >&2
  errors=1
}

# Patterns interdits dans le code de prod (sshprobe.go et autres
# fichiers non-_test.go). On filtre out les fichiers _test.go pour
# autoriser les callbacks serveur du fake server.
forbidden='ssh\.Password|ssh\.PublicKeys|ssh\.KeyboardInteractive|ssh\.RetryableAuthMethod'

prod_files=$(find "$target_dir" -type f -name "*.go" -not -name "*_test.go")

if [[ -n "$prod_files" ]]; then
  # `-H` force grep à toujours préfixer par le nom de fichier
  # (uniformise la sortie quand un seul fichier matche).
  # On ignore ensuite les lignes de commentaire (qui peuvent
  # légitimement mentionner ces patterns pour expliquer ce qui est
  # interdit).
  hits=$(grep -HnE "$forbidden" $prod_files 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*(//|/\*|\*)' \
    || true)
  if [[ -n "$hits" ]]; then
    fail "méthode d'authentification SSH détectée dans le code de prod :"
    echo "$hits" >&2
  fi
fi

if (( errors != 0 )); then
  echo "check_ssh_probe_no_auth: KO ($errors violations)" >&2
  exit 1
fi

echo "check_ssh_probe_no_auth: OK"
