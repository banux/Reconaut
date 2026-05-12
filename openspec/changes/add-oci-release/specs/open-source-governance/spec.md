# Spec delta : open-source-governance

## ADDED Requirements

### Requirement: Multi-arch OCI Image Release
La plateforme DOIT publier les images Docker des composants `api` et `scanner` sur GitHub Container Registry (GHCR) au format **multi-arch** (`linux/amd64` + `linux/arm64`), via un workflow CI déclenché par push de tag SemVer.

Contraintes :

- **Registry canonique** : `ghcr.io/banux/reconaut-<component>` (où `<component>` ∈ {`api`, `scanner`}). Pas de Docker Hub, Quay, ECR en v1.
- **Plateformes** : exactement `linux/amd64` ET `linux/arm64`. Pas d'arm/v7, pas de ppc64le.
- **Trigger** : workflow GitHub Actions `release.yml` déclenché par push de tag matching `v[0-9]+.[0-9]+.[0-9]+*` (SemVer + pre-release tolérés).
- **Tags publiés par image** :
  - `vX.Y.Z` (immuable, signé, SBOM attaché) — TOUJOURS.
  - `vX.Y` (flottant sur dernière patch) — uniquement pour releases stables (sans suffixe `-rc`/`-alpha`/...).
  - `vX` (flottant sur dernière minor stable) — idem.
  - `latest` (flottant sur dernière release stable) — idem.
- **Pas de tag pour les builds non-tagués**. Le push sur `main` n'écrit jamais sur GHCR.

#### Scenario: Tag v0.1.0 → 2 images multi-arch publiées
- **GIVEN** le repo est dans son état committed et le mainteneur fait `git tag v0.1.0 && git push --tags`
- **WHEN** le workflow `release.yml` s'exécute
- **THEN** `ghcr.io/banux/reconaut-api:v0.1.0` existe avec des manifests pour `linux/amd64` ET `linux/arm64`
- **AND** `ghcr.io/banux/reconaut-scanner:v0.1.0` idem
- **AND** `docker manifest inspect ghcr.io/banux/reconaut-api:v0.1.0 | jq '.manifests | length'` retourne 2

#### Scenario: Tag stable repousse latest, pre-release ne repousse pas
- **GIVEN** la dernière release stable est `v0.1.0` (le tag `latest` pointe dessus)
- **WHEN** le mainteneur push `v0.2.0-rc1`
- **THEN** `ghcr.io/banux/reconaut-api:v0.2.0-rc1` est publié et signé
- **AND** `ghcr.io/banux/reconaut-api:latest` continue de pointer sur `v0.1.0`

- **WHEN** le mainteneur push `v0.2.0` (stable)
- **THEN** `latest`, `v0`, `v0.2` repoussent sur `v0.2.0`
- **AND** `latest` ne pointe plus sur `v0.1.0`

#### Scenario: Pull arm64 réussit
- **GIVEN** une image `ghcr.io/banux/reconaut-api:v0.1.0` publiée
- **WHEN** un opérateur sur Apple Silicon ou AWS Graviton fait `docker pull ghcr.io/banux/reconaut-api:v0.1.0`
- **THEN** Docker pull la variante `linux/arm64` automatiquement (manifest list resolution)
- **AND** `docker run --rm ghcr.io/banux/reconaut-api:v0.1.0 bundle exec rails --version` réussit

### Requirement: CycloneDX SBOM per Image
La plateforme DOIT générer un SBOM CycloneDX par image publiée et le distribuer (a) comme attestation cosign attachée à l'image, (b) comme asset de la release GitHub téléchargeable sans cosign CLI.

Contraintes :

- **Format** : CycloneDX JSON 1.5+ (`.cdx.json`).
- **Outil** : `anchore/sbom-action@v0` (wrapper officiel de `syft`).
- **Couverture** : binaires + librairies système + gems Ruby (api) + modules Go (scanner). Toute dépendance directe ET transitive.
- **Asset release** : `sbom-reconaut-<component>-vX.Y.Z.cdx.json` attaché à la release GitHub.
- **Attestation cosign** : `cosign attest --type cyclonedx --predicate sbom.cdx.json ghcr.io/.../reconaut-<component>:vX.Y.Z`.

#### Scenario: Release v0.1.0 → 2 SBOM en asset
- **GIVEN** une release `v0.1.0` produite
- **WHEN** on inspecte la page GitHub Releases pour ce tag
- **THEN** deux assets sont présents : `sbom-reconaut-api-v0.1.0.cdx.json` et `sbom-reconaut-scanner-v0.1.0.cdx.json`
- **AND** chaque fichier est un JSON valide avec `bomFormat: "CycloneDX"`, `specVersion: >= "1.5"`, `components: [...]`
- **AND** la liste `components` contient au moins 50 entrées (estimation conservatrice — `ruby` + ses gems + libs système Debian)

#### Scenario: Attestation SBOM vérifiable via cosign
- **GIVEN** l'image `ghcr.io/banux/reconaut-api:v0.1.0`
- **WHEN** on lance `cosign verify-attestation --type cyclonedx --certificate-identity-regexp 'https://github.com/banux/Reconaut/.*' --certificate-oidc-issuer https://token.actions.githubusercontent.com ghcr.io/banux/reconaut-api:v0.1.0`
- **THEN** la vérification réussit
- **AND** `cosign download attestation --predicate-type=https://cyclonedx.org/bom ghcr.io/banux/reconaut-api:v0.1.0 | jq '.payload | @base64d | fromjson | .predicate.bomFormat'` retourne `"CycloneDX"`

### Requirement: Keyless Cosign Signature
La plateforme DOIT signer chaque image OCI publiée via **cosign keyless** (identité OIDC GitHub Actions, transparency log Rekor). Aucune clé privée long-lived n'est stockée.

Contraintes :

- **Outil** : `sigstore/cosign-installer@v3` puis `cosign sign --yes` (mode keyless implicite quand `COSIGN_EXPERIMENTAL=1` n'est plus requis depuis cosign 2.0).
- **Identité OIDC** : `https://github.com/banux/Reconaut/.github/workflows/release.yml@refs/tags/vX.Y.Z` (lié au workflow + tag).
- **Issuer** : `https://token.actions.githubusercontent.com`.
- **Rekor** : transparency log public ; chaque signature est inscrite avec timestamp vérifiable.

#### Scenario: Image signée vérifiable
- **GIVEN** l'image `ghcr.io/banux/reconaut-api:v0.1.0` publiée
- **WHEN** on lance :
  ```sh
  cosign verify \
    --certificate-identity-regexp 'https://github.com/banux/Reconaut/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    ghcr.io/banux/reconaut-api:v0.1.0
  ```
- **THEN** la commande retourne exit 0 et imprime le certificat + signature + entry Rekor
- **AND** une image non-signée du même registry (par ex. `nginx:latest`) retourne exit ≠ 0 sur la même commande

#### Scenario: Aucune clé long-lived dans le repo
- **GIVEN** le repo dans son état committed
- **WHEN** on grep pour les patterns `-----BEGIN.*PRIVATE KEY-----|cosign\.key|signing\.pem`
- **THEN** **aucun** match dans le repo (hors openspec docs / changelog qui peuvent mentionner ces patterns dans des explications)

### Requirement: Release Process Documentation
La plateforme DOIT documenter la procédure de release côté mainteneur ET la procédure de vérification côté opérateur. Un opérateur qui télécharge une image Reconaut DOIT pouvoir auditer sa supply chain sans connaissance préalable de cosign/syft.

Contraintes :

- **Côté mainteneur** : `docs/operating/release-process.md` documente la convention de versioning, les pré-conditions (CI verte, CHANGELOG mis à jour si présent), la commande de tag, le workflow déclenché.
- **Côté opérateur** : `docs/operating/verify-image.md` documente comment installer cosign, vérifier une image, extraire le SBOM, auditer les déps via le SBOM.

#### Scenario: docs/operating/release-process.md couvre les étapes mainteneur
- **GIVEN** le fichier dans son état committed
- **WHEN** on grep `git tag\|SemVer\|release.yml\|workflow`
- **THEN** au moins 4 mentions
- **AND** la commande `git tag vX.Y.Z` apparaît avec une explication de la convention

#### Scenario: docs/operating/verify-image.md couvre la vérification
- **GIVEN** le fichier dans son état committed
- **WHEN** on grep `cosign verify\|certificate-identity-regexp\|sbom\|cyclonedx`
- **THEN** au moins 4 mentions
- **AND** un exemple complet `cosign verify ...` est fourni

### Requirement: Post-Release Linter
La plateforme DOIT exposer un script `scripts/check_release_artifacts.sh` qui valide post-release qu'une version `vX.Y.Z` donnée porte bien (a) une image multi-arch sur GHCR, (b) une signature cosign vérifiable, (c) un SBOM en asset release. Utilisable manuellement par le mainteneur ou via workflow_dispatch.

#### Scenario: Le linter valide une release complète
- **GIVEN** une release `v0.1.0` publiée avec image + SBOM + signature
- **WHEN** `bash scripts/check_release_artifacts.sh v0.1.0` est exécuté
- **THEN** exit code 0
- **AND** stdout liste les artefacts vérifiés : image multi-arch (2 manifests), signature cosign (Rekor entry), SBOM asset téléchargé et JSON valide

#### Scenario: Le linter détecte une release incomplète
- **GIVEN** une release fictive `v0.0.0-invalid` qui n'existe pas
- **WHEN** `bash scripts/check_release_artifacts.sh v0.0.0-invalid` est exécuté
- **THEN** exit code ≠ 0 et le message identifie ce qui manque (image absente, ou SBOM manquant, ou signature non vérifiable)
