# Processus de release (mainteneur)

Statut : **stable**.
Audience : mainteneur Reconaut qui prépare une nouvelle release publique.

Reconaut suit la convention **SemVer** (Semantic Versioning 2.0.0). Chaque release est :

1. Taguée explicitement par le mainteneur (`git tag -a vX.Y.Z`).
2. Buildée en multi-arch (amd64 + arm64) via le workflow `release.yml`.
3. Signée via **cosign keyless** (identité OIDC GitHub Actions, transparency log Rekor).
4. Accompagnée d'un **SBOM CycloneDX** par image, attaché à la release GitHub.

## Convention de versioning

Format : `vMAJOR.MINOR.PATCH[-PRERELEASE]`.

| Cas                                  | Exemple             | Effet sur les tags publiés                          |
|--------------------------------------|---------------------|-----------------------------------------------------|
| Release stable                       | `v0.1.0`, `v1.0.0`  | `vX.Y.Z`, `vX.Y`, `vX`, `latest` (flottants stables) |
| Release candidate                    | `v0.2.0-rc1`        | `vX.Y.Z-rc1` UNIQUEMENT — `latest` reste sur l'ancien |
| Pre-release alpha/beta               | `v1.0.0-alpha.1`    | Idem — pas de tag flottant repoussé                  |

**Pré-1.0** : breaking changes possibles entre minor (`v0.1.x` → `v0.2.x`). À partir de v1.0 stable, breaking → bump major.

## Pré-conditions de release

Avant de tag, vérifier :

- **CI verte sur `main`** : tous les jobs `stack-lint`, `api-rspec`, `scanner-go-test`, `docs`, `verify-release` doivent être verts sur le commit HEAD.
- **OpenSpec à jour** : `bundle exec openspec validate` (si disponible) ne signale aucune divergence.
- **CHANGELOG** : si un `CHANGELOG.md` existe, mettre à jour la section pour la version qui va être taguée. (Pas encore présent en v0.x — `add-changelog-generation` futur.)
- **Pas de PR `[WIP]` mergée à la dernière minute** sans relecture.

## Couper une release

```sh
# 1. S'assurer que main est à jour
git checkout main
git pull --ff-only

# 2. Choisir le tag (SemVer strict)
TAG=v0.1.0

# 3. Créer un tag annoté + push
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"
```

Le workflow `release.yml` se déclenche automatiquement sur push de tag matchant `v[0-9]+.[0-9]+.[0-9]+*`.

## Suivre le déroulement du workflow

```sh
# Dans le repo GitHub → onglet Actions → workflow "release"
# Ou via la CLI :
gh run watch --repo banux/Reconaut
```

Le workflow tourne typiquement en 10-15 minutes. Étapes :

1. **`build-and-push`** (matrix api + scanner) :
   - QEMU pour cross-compile arm64 sur runner amd64.
   - `docker buildx` build multi-arch (~5-8 min par image).
   - Push sur `ghcr.io/banux/reconaut-{api,scanner}:vX.Y.Z` + tags flottants.

2. **`sbom-and-sign`** (matrix api + scanner) :
   - `anchore/sbom-action` génère le SBOM CycloneDX.
   - `cosign sign` signe l'image (identité OIDC GitHub Actions).
   - `cosign attest --type cyclonedx` attache le SBOM comme attestation.
   - `softprops/action-gh-release` uploade le `.cdx.json` en asset de la release.

## Vérification post-release

Une fois le workflow vert, vérifier localement :

```sh
# Requiert : docker, cosign, gh CLI authentifié, jq
bash scripts/check_release_artifacts.sh v0.1.0
```

Le script vérifie :

- **Images multi-arch présentes** : `docker manifest inspect` retourne 2 plateformes.
- **Signature cosign vérifiable** : `cosign verify` avec l'identité GitHub Actions.
- **SBOM en asset** : `gh release view` confirme `sbom-reconaut-{api,scanner}-vX.Y.Z.cdx.json` présents, parse JSON valide.

En cas d'échec : ne pas annoncer la release. Investiguer le job correspondant dans GitHub Actions, fixer, et retag (sur un patch bump si déjà publié).

## Bump du chart Helm + docker-compose post-1re release

Une fois `v0.1.0` publié, créer un PR de suivi :

```sh
# deploy/helm/reconaut/values.yaml
sed -i 's|repository: reconaut/api|repository: ghcr.io/banux/reconaut-api|' deploy/helm/reconaut/values.yaml
sed -i 's|tag: 0.1.0-dev|tag: v0.1.0|' deploy/helm/reconaut/values.yaml
# Idem pour scanner.

# docker-compose.yml (optionnel — garder `build:` pour le dev local)
sed -i 's|reconaut/api:0.1.0-dev|ghcr.io/banux/reconaut-api:v0.1.0|' docker-compose.yml
sed -i 's|reconaut/scanner:0.1.0-dev|ghcr.io/banux/reconaut-scanner:v0.1.0|' docker-compose.yml
```

PR séparé pour que la release elle-même soit atomique (pas de chicken-and-egg avec un tag qui pointe vers un commit qui référence le tag).

## Workflow `verify-release.yml`

Un workflow distinct (`verify-release.yml`) :

- **Manual** (`workflow_dispatch`) : vérifie une release passée à la demande, avec un input `tag`.
- **Cron mensuel** : 1er de chaque mois 03:00 UTC, vérifie automatiquement la dernière release stable. Alerte si une image a été supprimée du registry ou si Rekor a un problème.

Trigger manuel :

```
GitHub → Actions → "verify-release" → Run workflow → tag: v0.1.0
```

## Procédure d'urgence : retirer une release compromise

Si une release a été publiée par accident (mauvaise branche, secret leaké, code malveillant injecté en pre-merge) :

1. **Marquer la release comme draft / supprimer** dans GitHub Releases.
2. **Supprimer les images** du registry GHCR (`Packages → reconaut-api → Delete version`).
3. **Bumper immédiatement** vers `vX.Y.(Z+1)` avec le fix, sans réutiliser le tag retiré.
4. Communication publique (issue / discussion) expliquant le retrait et la version à utiliser à la place.

Cosign + Rekor garantissent que la signature reste **vérifiablement émise par le workflow GitHub**, mais Rekor n'efface pas une entrée — c'est append-only. Un opérateur paranoïaque qui vérifie en arrière les SBOM saura quand l'image a disparu du registry.

## Liens

- `.github/workflows/release.yml` — le workflow qui produit la release.
- `.github/workflows/verify-release.yml` — le workflow de vérification.
- `scripts/check_release_artifacts.sh` — linter post-release.
- [`verify-image.md`](verify-image.md) — guide opérateur pour vérifier une release publiée.
- `openspec/changes/add-oci-release/` — change qui livre la plomberie.
