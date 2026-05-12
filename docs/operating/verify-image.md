# Vérifier une image Reconaut (opérateur)

Statut : **stable**.
Audience : opérateur qui veut auditer la chaîne d'approvisionnement avant de déployer une image Reconaut.

Chaque image publiée par Reconaut (`ghcr.io/banux/reconaut-api`, `ghcr.io/banux/reconaut-scanner`) est :

1. **Multi-arch** (`linux/amd64` + `linux/arm64`) — `docker pull` résout automatiquement la variante.
2. **Signée** via **cosign keyless** (identité OIDC GitHub Actions, transparency log Rekor).
3. Accompagnée d'un **SBOM CycloneDX** disponible (a) comme attestation cosign attachée à l'image, (b) comme asset téléchargeable de la release GitHub.

Ce document explique comment vérifier ces propriétés avant de déployer.

## Installer cosign

`cosign` est l'outil officiel sigstore. Pas de clé à gérer — la vérification utilise l'identité OIDC du workflow GitHub qui a signé.

### macOS / Linux

```sh
# Homebrew
brew install cosign

# Linux binaire direct
curl -fsSL https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign-linux-amd64 -o /usr/local/bin/cosign
chmod +x /usr/local/bin/cosign

cosign version
```

### Container

```sh
docker run --rm gcr.io/projectsigstore/cosign:v2.4.1 version
```

## Vérifier la signature d'une image

```sh
TAG=v0.1.0   # ou n'importe quel tag publié

cosign verify \
  --certificate-identity-regexp 'https://github.com/banux/Reconaut/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/banux/reconaut-api:$TAG
```

Sortie attendue (extrait) :

```
Verification for ghcr.io/banux/reconaut-api:v0.1.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates

[
  {
    "critical": {
      "identity": { "docker-reference": "ghcr.io/banux/reconaut-api" },
      "image": { "docker-manifest-digest": "sha256:..." },
      "type": "cosign container image signature"
    },
    "optional": {
      "Issuer": "https://token.actions.githubusercontent.com",
      "Subject": "https://github.com/banux/Reconaut/.github/workflows/release.yml@refs/tags/v0.1.0"
    }
  }
]
```

Exit code 0 ⇒ image vérifiée. Le **Subject** confirme que l'image a été produite par le workflow `release.yml` au tag `v0.1.0` — preuve de l'origine.

### Que signifie un échec ?

```
Error: no matching signatures
```

Possibilités :

- **Image trojanisée** : push manuel par un attaquant qui a compromis le registry mais pas le workflow.
- **Tag déplacé** : le tag `v0.1.0` pointe vers une nouvelle image jamais signée par le workflow attendu.
- **Cosign mal configuré** : `--certificate-identity-regexp` ne matche pas (par ex. tu pointes sur un fork).

Dans tous les cas : **ne déploie pas** l'image. Vérifie avec le mainteneur via une autre voie (issue GitHub, contact direct).

## Vérifier la signature des deux composants

```sh
TAG=v0.1.0
for comp in api scanner; do
  echo "=== $comp ==="
  cosign verify \
    --certificate-identity-regexp 'https://github.com/banux/Reconaut/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    ghcr.io/banux/reconaut-$comp:$TAG
done
```

## Télécharger et lire le SBOM CycloneDX

### Option A : asset de la release GitHub (sans cosign)

```sh
TAG=v0.1.0
gh release download $TAG --repo banux/Reconaut \
  --pattern "sbom-reconaut-*-$TAG.cdx.json"

# Ou via curl direct si tu n'as pas gh CLI
curl -fsSL -o sbom-api.cdx.json \
  "https://github.com/banux/Reconaut/releases/download/$TAG/sbom-reconaut-api-$TAG.cdx.json"
```

### Option B : attestation cosign

```sh
cosign download attestation \
  --predicate-type=https://cyclonedx.org/bom \
  ghcr.io/banux/reconaut-api:$TAG \
  | jq -r '.payload' | base64 -d | jq '.predicate' > sbom-api.cdx.json
```

### Structure d'un SBOM CycloneDX

```json
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:...",
  "version": 1,
  "metadata": {
    "timestamp": "2026-05-12T...",
    "tools": [{ "vendor": "anchore", "name": "syft", "version": "..." }]
  },
  "components": [
    {
      "type": "library",
      "name": "rails",
      "version": "8.1.3",
      "purl": "pkg:gem/rails@8.1.3",
      "licenses": [{ "license": { "id": "MIT" } }]
    },
    { "...": "..." }
  ]
}
```

## Auditer les dépendances via le SBOM

### Compter les composants

```sh
jq '.components | length' sbom-api.cdx.json
# → 234 (exemple)
```

### Lister les licences présentes

```sh
jq -r '.components[].licenses[]?.license.id // .components[].licenses[]?.license.name' sbom-api.cdx.json \
  | sort -u
```

Ce que tu attends pour Reconaut : MIT, Apache-2.0, BSD-2/3-Clause, AGPL-3.0-only, ISC, MPL-2.0, Ruby. Toute licence inhabituelle (GPL-2.0 strict, SSPL, BSL) mérite une vérification.

### Chercher une dépendance spécifique (CVE check ad-hoc)

```sh
# Toutes les versions de Rails dans le SBOM
jq -r '.components[] | select(.name == "rails") | "\(.name)@\(.version)"' sbom-api.cdx.json

# Cherche par PURL prefix (par ex. tous les modules Go)
jq -r '.components[] | select(.purl | startswith("pkg:golang/")) | "\(.name)@\(.version)"' sbom-scanner.cdx.json
```

### Croiser avec une base CVE

Outils tiers qui consomment des SBOM CycloneDX et alertent sur les CVE :

- **`grype sbom:sbom-api.cdx.json`** — scanner Anchore.
- **`trivy sbom sbom-api.cdx.json`** — scanner Aqua.
- **`osv-scanner --sbom sbom-api.cdx.json`** — scanner Google OSV.

Reconaut **ne** fait **pas** lui-même le scan CVE — c'est différé à `add-image-vulnerability-scan` futur. En attendant, ces outils externes consomment directement le SBOM publié.

## Résumé : workflow opérateur recommandé

```sh
TAG=v0.1.0

# 1. Vérifier signature des 2 images
for comp in api scanner; do
  cosign verify \
    --certificate-identity-regexp 'https://github.com/banux/Reconaut/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    ghcr.io/banux/reconaut-$comp:$TAG > /dev/null \
    && echo "✓ $comp signé" \
    || { echo "✗ $comp NON signé — arrêt" ; exit 1; }
done

# 2. Télécharger les SBOM
gh release download $TAG --repo banux/Reconaut \
  --pattern "sbom-reconaut-*-$TAG.cdx.json"

# 3. Vérifier le format CycloneDX
for f in sbom-reconaut-*-$TAG.cdx.json; do
  jq -e '.bomFormat == "CycloneDX"' "$f" > /dev/null \
    && echo "✓ $f valide ($(jq '.components | length' "$f") composants)"
done

# 4. (Optionnel) Scanner CVE
grype sbom:sbom-reconaut-api-$TAG.cdx.json
```

Si toutes les étapes passent, l'image est :

- **Authentique** : produite par le workflow `release.yml` du repo banux/Reconaut.
- **Auditable** : le SBOM permet de reproduire la liste des dépendances.
- **Tracée publiquement** : la signature est inscrite dans Rekor (transparency log immuable).

## Liens

- [`release-process.md`](release-process.md) — côté mainteneur : comment ces artefacts sont produits.
- [`deployment-helm.md`](deployment-helm.md) — déployer une image vérifiée via Helm.
- [`deployment-docker-compose.md`](deployment-docker-compose.md) — déployer via docker-compose.
- `openspec/changes/add-oci-release/` — change qui livre la plomberie.
- [sigstore/cosign](https://docs.sigstore.dev/cosign/system_config/installation/) — documentation cosign officielle.
- [CycloneDX](https://cyclonedx.org/) — spec SBOM officielle.
