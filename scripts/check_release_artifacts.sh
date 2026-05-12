#!/usr/bin/env bash
# scripts/check_release_artifacts.sh — valide qu'une release publiée
# porte bien tous les artefacts attendus :
#   - 2 images OCI multi-arch (api + scanner) sur GHCR
#   - signature cosign keyless vérifiable
#   - SBOM CycloneDX en asset de la release GitHub
#
# Usage :
#   ./scripts/check_release_artifacts.sh v0.1.0
#
# Cf. openspec/changes/add-oci-release/specs/open-source-governance/spec.md
#   -> Requirement: Post-Release Linter
#
# Pré-requis :
#   - docker (pour `docker manifest inspect`)
#   - cosign 2.x (pour `cosign verify`)
#   - gh CLI authentifié (pour `gh release view/download`)
#   - jq

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <tag>" >&2
  echo "       par exemple: $0 v0.1.0" >&2
  exit 64
fi

TAG="$1"
ORG="${RECONAUT_RELEASE_ORG:-banux}"
REGISTRY="ghcr.io"
COMPONENTS=(api scanner)
errors=0

fail() {
  echo "release-artifacts: $1" >&2
  errors=1
}

check_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    fail "outil requis manquant : $tool"
    return 1
  fi
}

# --- 0. Outils ---------------------------------------------------------------
check_tool docker || true
check_tool cosign || true
check_tool gh     || true
check_tool jq     || true

if (( errors != 0 )); then
  echo "release-artifacts: pré-requis non satisfaits — installe docker, cosign, gh, jq" >&2
  exit 1
fi

echo "[release-artifacts] vérification du tag $TAG (org=$ORG)"
echo

# --- 1. Images multi-arch sur GHCR ------------------------------------------
for comp in "${COMPONENTS[@]}"; do
  ref="$REGISTRY/$ORG/reconaut-$comp:$TAG"
  echo "[1/$((${#COMPONENTS[@]})))]  Vérification manifest multi-arch : $ref"

  if ! manifest=$(docker manifest inspect "$ref" 2>&1); then
    fail "manifest $ref introuvable :\n$manifest"
    continue
  fi

  count=$(echo "$manifest" | jq '.manifests | length' 2>/dev/null || echo 0)
  if [[ "$count" -lt 2 ]]; then
    fail "$ref : seulement $count plateforme(s) (attendu ≥ 2 : amd64+arm64)"
  else
    plats=$(echo "$manifest" | jq -r '.manifests[].platform | "\(.os)/\(.architecture)"' | sort | tr '\n' ' ')
    echo "       ✓ plateformes : $plats"
  fi
done
echo

# --- 2. Signature cosign keyless vérifiable ---------------------------------
for comp in "${COMPONENTS[@]}"; do
  ref="$REGISTRY/$ORG/reconaut-$comp:$TAG"
  echo "[2/$((${#COMPONENTS[@]})))]  Vérification cosign : $ref"

  if ! out=$(COSIGN_EXPERIMENTAL=0 cosign verify \
        --certificate-identity-regexp "https://github.com/$ORG/Reconaut/.*" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        "$ref" 2>&1); then
    fail "cosign verify a échoué pour $ref :\n$out"
  else
    echo "       ✓ signature valide (Rekor entry présente)"
  fi
done
echo

# --- 3. SBOM CycloneDX en asset GitHub --------------------------------------
release_assets=$(gh release view "$TAG" --repo "$ORG/Reconaut" --json assets --jq '.assets[].name' 2>&1) || {
  fail "gh release view a échoué pour $TAG :\n$release_assets"
  release_assets=""
}

for comp in "${COMPONENTS[@]}"; do
  expected="sbom-reconaut-$comp-$TAG.cdx.json"
  echo "[3/$((${#COMPONENTS[@]})))]  Vérification asset SBOM : $expected"
  if ! echo "$release_assets" | grep -qFx "$expected"; then
    fail "asset $expected absent de la release $TAG"
    continue
  fi
  # Télécharge et valide le JSON CycloneDX
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  if ! gh release download "$TAG" --repo "$ORG/Reconaut" --pattern "$expected" --dir "$tmpdir" >/dev/null 2>&1; then
    fail "gh release download a échoué pour $expected"
    continue
  fi
  if ! jq -e '.bomFormat == "CycloneDX"' "$tmpdir/$expected" >/dev/null; then
    fail "$expected : bomFormat != CycloneDX"
    continue
  fi
  comp_count=$(jq '.components | length' "$tmpdir/$expected")
  echo "       ✓ JSON CycloneDX valide ($comp_count components)"
done
echo

# --- Résumé ------------------------------------------------------------------
if (( errors != 0 )); then
  echo "release-artifacts: KO ($errors violations pour $TAG)" >&2
  exit 1
fi

echo "release-artifacts: OK — $TAG porte tous les artefacts attendus"
