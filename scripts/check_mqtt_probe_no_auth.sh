#!/usr/bin/env bash
# scripts/check_mqtt_probe_no_auth.sh — garantit que le sondeur MQTT
# n'introduit JAMAIS de credential ni d'API mutante (PUBLISH /
# SUBSCRIBE / UNSUBSCRIBE / Will).
#
# Source de vérité :
#   openspec/changes/add-mqtt-probe/specs/scanning/spec.md
#     -> Requirement: MQTT Broker Probe
#     -> Scenario: Aucune authentification jamais tentée (audit statique)
#
# Le sondeur s'arrête après CONNECT + CONNACK + DISCONNECT. Toute
# introduction d'username/password (bruteforce) OU de PUBLISH /
# SUBSCRIBE / Will (écoute ou réinjection de payload utilisateur)
# viole le contrat — Reconaut n'est PAS un outil offensif.

set -euo pipefail

cd "$(dirname "$0")/.."

target_dir="apps/scanner/internal/mqttprobe"

if [[ ! -d "$target_dir" ]]; then
  echo "check_mqtt_probe_no_auth: skip ($target_dir absent)" >&2
  exit 0
fi

errors=0

fail() {
  echo "mqtt-probe-no-auth: $1" >&2
  errors=1
}

# Patterns interdits dans le code de prod (hors *_test.go).
# - credential / password / username : interdit anti-bruteforce.
# - WillTopic / WillMessage : interdit anti-payload-injection.
# - Publish( / Subscribe( / Unsubscribe( : interdit anti-écoute-topics.
forbidden='password|credential|username|WillTopic|WillMessage|Publish\(|Subscribe\(|Unsubscribe\('

prod_files=$(find "$target_dir" -type f -name "*.go" -not -name "*_test.go")

if [[ -n "$prod_files" ]]; then
  hits=$(grep -iHnE "$forbidden" $prod_files 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*(//|/\*|\*)' \
    `# Allowlist : labels du CONNACK return_code MQTT 3.1.1 (cf.` \
    `# spec MQTT-3.1.1 §3.2.2.3) — la chaîne` \
    `# "bad_username_or_password" est le standard pour rc=4 et` \
    `# n'implique aucun envoi de credential.` \
    | grep -vE 'return[[:space:]]+"(bad_username_or_password)"' \
    || true)
  if [[ -n "$hits" ]]; then
    fail "construction d'auth / publish / subscribe interdite dans $target_dir :"
    echo "$hits" >&2
  fi
fi

if (( errors != 0 )); then
  echo "check_mqtt_probe_no_auth: KO ($errors violations)" >&2
  exit 1
fi

echo "check_mqtt_probe_no_auth: OK"
