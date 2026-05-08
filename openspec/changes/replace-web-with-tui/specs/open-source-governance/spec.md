# Spec delta : open-source-governance

## MODIFIED Requirements

### Requirement: Reproducible Container Distribution
Le projet DOIT publier des images de container OCI multi-arch (au minimum `linux/amd64` et `linux/arm64`) pour chaque application **serveur** cœur (`api`, `scanner-<kind>` pour chaque `scan_kind`) à chaque release SemVer. Le **binaire opérateur** `reconautctl` DOIT être publié comme **binaires statiques** multi-arch (`linux/amd64`, `linux/arm64`, `darwin/amd64`, `darwin/arm64`) attachés à la release GitHub, **pas** comme une image OCI (un binaire opérateur n'a pas vocation à tourner en container).

Toutes les images DOIVENT être construites depuis le repo public via un workflow CI auditable, taguées par version SemVer, accompagnées d'un SBOM CycloneDX et signées via cosign keyless. Tous les binaires `reconautctl` DOIVENT être accompagnés d'un fichier `SHA256SUMS` signé par cosign.

La reproductibilité fonctionnelle (même Dockerfile / même Go toolchain + même lockfile = même set de couches non-builder / mêmes binaires) est exigée ; la reproductibilité bit-à-bit est désirable mais non bloquante.

#### Scenario: Release vX.Y.Z publiée avec images, binaires, SBOM, signatures
- **GIVEN** un tag SemVer `vX.Y.Z` est poussé
- **WHEN** le workflow `release.yml` s'exécute
- **THEN** pour l'app `api`, une image `ghcr.io/<org>/reconaut-api:vX.Y.Z` est publiée pour `amd64` et `arm64`
- **AND** pour chaque `scan_kind` supporté, une image `ghcr.io/<org>/reconaut-scanner-<kind>:vX.Y.Z` est publiée pour `amd64` et `arm64`
- **AND** pour chaque combinaison os/arch supportée, un binaire `reconautctl-<os>-<arch>` est publié comme asset de la release GitHub
- **AND** un SBOM CycloneDX est attaché pour chaque image et chaque binaire
- **AND** `cosign verify ...` réussit sur chaque image et chaque binaire
- **AND** un check CI échoue si une release sort sans l'un de ces artefacts pour l'un de ses composants

#### Scenario: Aucune image OCI pour reconautctl
- **GIVEN** la release publiée
- **WHEN** un opérateur consulte les tags du registry GHCR
- **THEN** il n'existe pas d'image `ghcr.io/<org>/reconaut-tui:*` ni `ghcr.io/<org>/reconaut-web:*` (ni l'un ni l'autre n'a de sens dans la stack v1)

#### Scenario: Build reproductible fonctionnel
- **GIVEN** un commit `C` et son lockfile correspondant
- **WHEN** le pipeline build l'image `api` deux fois sur deux runners distincts
- **THEN** les digests des couches non-builder (couches d'application, pas la couche d'OS de base) sont identiques entre les deux builds
- **AND** la même propriété tient pour le build des binaires `scanner-<kind>` et `reconautctl` (digests SHA-256 identiques entre runners)
