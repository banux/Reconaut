#!/usr/bin/env bash
# scripts/check_modbus_probe_no_write.sh — garantit que le sondeur
# Modbus n'introduit JAMAIS de fonction write (Write*Coil*, Write*Register*,
# MaskWriteRegister, ReadWriteMultipleRegisters) ni Diagnostics
# (peut RESET un device industriel — interdit en outil ASM).
#
# Source de vérité :
#   openspec/changes/add-worker-modbus/specs/scanning/spec.md
#     -> Requirement: Modbus TCP Device Fingerprint
#     -> Scenario: Aucune méthode write ni Diagnostics (audit statique)
#
# Reconaut N'EST PAS un outil offensif. Toute introduction de fonction
# mutante côté worker peut **arrêter une chaîne industrielle**.

set -euo pipefail

cd "$(dirname "$0")/.."

target_dir="apps/scanner/internal/modbusprobe"

if [[ ! -d "$target_dir" ]]; then
  echo "check_modbus_probe_no_write: skip ($target_dir absent)" >&2
  exit 0
fi

errors=0

fail() {
  echo "modbus-probe-no-write: $1" >&2
  errors=1
}

# Noms symboliques interdits. On évite les opcodes hex (faux positifs),
# on s'appuie sur les noms standards de la spec Modbus.
forbidden='WriteSingleCoil|WriteMultipleCoils|WriteSingleRegister|WriteMultipleRegisters|MaskWriteRegister|ReadWriteMultipleRegisters|Diagnostics|Restart\b|ForceCoil|PresetRegister|fnDiagnostics|fnRestart|fnWrite'

prod_files=$(find "$target_dir" -type f -name "*.go" -not -name "*_test.go")

if [[ -n "$prod_files" ]]; then
  hits=$(grep -HnE "$forbidden" $prod_files 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*(//|/\*|\*)' \
    || true)
  if [[ -n "$hits" ]]; then
    fail "fonction mutante / Diagnostics interdite dans $target_dir :"
    echo "$hits" >&2
  fi
fi

if (( errors != 0 )); then
  echo "check_modbus_probe_no_write: KO ($errors violations)" >&2
  exit 1
fi

echo "check_modbus_probe_no_write: OK"
