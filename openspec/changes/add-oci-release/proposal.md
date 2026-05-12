# Change : add-oci-release

## Pourquoi

`init-reconaut-platform` §8.1 demande des **images OCI multi-arch** (amd64 + arm64) publiées sur GHCR avec tag SemVer + `latest` flottant. §8.2 demande **SBOM CycloneDX** + **signature Sigstore/cosign keyless** par image. L'acceptance line **L266** *"Une release publique a été produite avec image OCI multi-arch signée et SBOM CycloneDX attaché"* dépend des deux.

État actuel après `add-helm-chart` :

- Les Dockerfiles existent (`apps/api/Dockerfile`, `apps/scanner/Dockerfile`) mais sont **buildés localement** (`docker compose build`). Pas de tag SemVer, pas de registry publié, single-arch.
- Le chart Helm pointe vers `reconaut/api:0.1.0-dev` qui n'existe **dans aucun registry public** — un opérateur qui `helm install` doit d'abord builder les images lui-même.
- Aucun SBOM, aucune signature. Un attaquant pourrait introduire une image trojanisée sans déclencher d'alerte.

Trois trous concrets que ce change ferme :

1. **Pas de release reproductible.** Un opérateur sur arm64 (Apple Silicon, AWS Graviton, Raspberry Pi pour lab) ne peut pas pull une image officielle.
2. **Pas de chaîne d'approvisionnement vérifiable.** Sans SBOM + signature, `helm install reconaut` exécute du code non-attesté. Posture sécurité incompatible avec un opérateur qui audit sa supply chain.
3. **L266 bloquée.** L'acceptance globale ne peut pas être tickée sans release publique.

## Ce qui change

1. **Workflow CI `.github/workflows/release.yml`** déclenché par push de tag `v[0-9]+.[0-9]+.[0-9]+*` (SemVer strict + suffixes pre-release autorisés `v0.1.0-rc1`, `v1.0.0-alpha`, etc.).

2. **Build multi-arch via `docker buildx`** :
   - 2 plateformes : `linux/amd64`, `linux/arm64`. Pas d'arm/v7, pas de ppc64le en v1 — couverture des deux archis grand public suffit.
   - Cache exporté/importé via `type=gha` (cache GitHub Actions) pour accélérer les builds successifs.
   - 2 images par release : `ghcr.io/banux/reconaut-api` et `ghcr.io/banux/reconaut-scanner`.

3. **Tags publiés** par image :
   - `vX.Y.Z` (immuable, signé, SBOM attaché).
   - `vX.Y` (flottant sur la dernière patch).
   - `vX` (flottant sur la dernière minor stable).
   - `latest` (flottant sur la dernière release stable — non publié pour les pre-release `-rc`).

4. **SBOM CycloneDX via `anchore/sbom-action@v0`** :
   - 1 fichier `.cdx.json` par image (api + scanner) + 1 fichier pour le repo source.
   - Attaché à la release GitHub comme asset téléchargeable (`sbom-reconaut-api-vX.Y.Z.cdx.json`, etc.).
   - Aussi attaché comme attestation sur l'image elle-même via `cosign attest`.

5. **Signature keyless via `sigstore/cosign-installer@v3` + `cosign sign`** :
   - Identité OIDC GitHub Actions (`sigstore-conformance` workflow identity).
   - Aucune clé privée stockée. La transparence vient de Rekor (transparency log).
   - Signature des manifests d'image + des SBOM attestations.

6. **Linter `scripts/check_release_artifacts.sh`** : vérifie qu'une release publiée porte bien (a) une image vX.Y.Z multi-arch, (b) un SBOM en asset, (c) une signature cosign vérifiable. Tourne en post-release (workflow_dispatch ou cron) plutôt qu'en CI standard.

7. **Documentation** :
   - `docs/operating/release-process.md` : guide mainteneur (tag SemVer, attendu, vérification post-release).
   - `docs/operating/verify-image.md` : guide opérateur (`cosign verify` + extraction SBOM + audit déps).
   - Mise à jour de `deploy/helm/reconaut/values.yaml` : tag par défaut bumpé à `v0.1.0` quand la première release sera coupée (post-merge).

8. **Politique de version** : pré-1.0 = breaking changes possibles entre minor. À partir de v1.0, breaking → bump major. Documenté dans `docs/operating/release-process.md`.

## Contraintes

- **Pas de signature avec clé privée stockée**. Cosign keyless via OIDC GitHub uniquement. Cohérent avec project.md (*pas de secret long-lived dans le repo*).
- **Pas de registry tiers** (Docker Hub, Quay). GHCR est le canal canonique — c'est gratuit pour les OSS, intégré nativement aux GitHub Actions, et permet une politique de retention propre.
- **Pas de signature GPG legacy**. Cosign uniquement (sigstore est le standard de fait depuis 2022).
- **Pas d'image `latest` pour les pre-release**. Seules les versions stables (`v[0-9]+\.[0-9]+\.[0-9]+$` sans suffixe) repoussent le tag `latest`.
- **Pas d'image attaquable pour les builds non-tagués**. Le workflow `release.yml` ne se déclenche QUE sur push de tag. Les push sur `main` continuent à utiliser le workflow `ci.yml` existant sans publier d'image.
- **AGPL clean**. Les actions GitHub utilisées (`docker/setup-buildx-action`, `docker/login-action`, `docker/build-push-action`, `anchore/sbom-action`, `sigstore/cosign-installer`) sont toutes Apache-2.0 ou MIT — compatibles AGPL.
- **Pas de nouvelle dépendance runtime**. Les outils (`buildx`, `syft`, `cosign`) tournent uniquement en CI ; aucun ne se retrouve dans le runtime des images publiées.

## Non-objectifs (hors scope de ce change)

- **Publication automatique sur registries tiers** (Docker Hub, Quay, AWS ECR Public) — différé à `add-multi-registry-mirror`.
- **Build sur arm/v7 ou autres archis exotiques** — différé à `add-arch-armv7` si la demande émerge.
- **Bundle Helm chart en OCI artifact** (`helm push deploy/helm/reconaut oci://...`) — différé à `add-helm-oci-publish`.
- **Génération automatique de changelog** depuis git log — relève d'`add-changelog-generation` (utiliserait `git-cliff` ou similaire).
- **Release-please ou semantic-release automation** — la cadence v1 est manuelle (le mainteneur tag explicitement). Différé à `add-release-automation` quand la cadence augmentera.
- **Reproducible builds** (SOURCE_DATE_EPOCH, déterminisme bit-à-bit) — relève d'`add-reproducible-builds`. Important mais hors scope du chantier de publication initial.
- **Vulnerability scanning** (`grype`, `trivy`) sur les images publiées — différé à `add-image-vulnerability-scan`. La signature Sigstore garantit l'origine, pas l'absence de CVE.
- **Image rootless distroless** pour `apps/api/Dockerfile` — la v1 utilise `ruby:3.4-slim` (root). Le hardening est différé à `add-rootless-images`.

## Décisions prises

1. **GHCR exclusif en v1**. Multi-registry (Docker Hub + Quay) ajoute de la complexité d'auth et de retention sans valeur immédiate. GHCR est gratuit pour OSS, intégré aux workflows, suffit pour `helm pull` et `docker pull`.
2. **Cosign keyless plutôt que keyful**. Pas de gestion de clé KMS, pas de secret rotation. L'identité de signature est l'identité du workflow GitHub qui a poussé l'image — vérifiable via Rekor public log.
3. **SBOM en attestation cosign + asset release**. Les deux : l'attestation permet `cosign verify-attestation`, l'asset permet un download direct sans cosign installé. Double diffusion pour ne pas exclure les opérateurs sans cosign CLI.
4. **`anchore/sbom-action` plutôt que `syft` direct**. L'action wrappe syft avec une gestion propre des artefacts GitHub. Pas de différence fonctionnelle, juste moins de scripting.
5. **Trigger uniquement sur tag SemVer**. Pas de release automatique sur chaque merge `main` — trop bruyant. Le mainteneur décide quand release via `git tag vX.Y.Z && git push --tags`.
6. **2 archis seulement (amd64 + arm64)**. Couvre ~99% des opérateurs (cloud + Apple Silicon + Pi 4/5). arm/v7 (Pi 3) ou ppc64le ajouteraient ~3 min de build pour < 1% d'usage.

## Différé (non bloquant, parqué pour plus tard)

- **`add-multi-registry-mirror`** : mirror automatique sur Docker Hub / Quay / ECR Public.
- **`add-helm-oci-publish`** : `helm push` du chart en OCI artifact sur GHCR.
- **`add-changelog-generation`** : `git-cliff` génère le CHANGELOG.md à partir des Conventional Commits.
- **`add-release-automation`** : `release-please` ou `semantic-release` pour automatiser le tagging.
- **`add-reproducible-builds`** : déterminisme bit-à-bit via SOURCE_DATE_EPOCH + flags compilo.
- **`add-image-vulnerability-scan`** : `grype` / `trivy` en CI post-release, échec si CVE critique.
- **`add-rootless-images`** : api en distroless rootless, scanner déjà nonroot.
- **`add-image-attestation-policy`** : Kyverno policy qui refuse les pods non-signés Reconaut dans le namespace de prod.
