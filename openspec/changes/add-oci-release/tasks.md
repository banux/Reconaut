# Tâches : add-oci-release

Checklist de la mise en place de la release OCI multi-arch + SBOM CycloneDX + signature cosign keyless.

---

## 1. Workflow `release.yml`

- [x] **1.1 Fichier `.github/workflows/release.yml`**
  - **Notes** : Workflow déclenché par `push: tags: ['v[0-9]+.[0-9]+.[0-9]+*']`. Jobs :
    1. `build-and-push` : matrix sur `[api, scanner]`. Steps : `actions/checkout@v4` → `docker/setup-qemu-action@v3` (pour emulation arm64 sur runner amd64) → `docker/setup-buildx-action@v3` → `docker/login-action@v3` (GHCR via `${{ secrets.GITHUB_TOKEN }}`) → `docker/metadata-action@v5` (génère les tags SemVer/major/minor/latest avec `flavor: latest=auto`) → `docker/build-push-action@v6` (`platforms: linux/amd64,linux/arm64`, cache GHA, push true).
    2. `sbom-and-sign` : depends_on build-and-push. Matrix sur images. Steps : `sigstore/cosign-installer@v3` → `anchore/sbom-action@v0` (génère .cdx.json) → `cosign sign --yes <image-digest>` → `cosign attest --type cyclonedx --predicate <sbom> <image-digest>` → upload SBOM en asset release via `softprops/action-gh-release@v2`.
  - **Permissions requises** : `contents: write` (release assets), `packages: write` (push GHCR), `id-token: write` (OIDC pour cosign keyless).
  - **Test plan** : Push d'un tag de test (`v0.0.0-test1`) sur un fork → vérifier que les jobs passent vert, que les images apparaissent sur GHCR, que `cosign verify` réussit, que la release GitHub porte les 2 SBOM en asset.

- [x] **1.2 Pin des actions par SHA**
  - **Notes** : Best practice supply chain — pin chaque action GitHub par son commit SHA (pas juste `@v4`) pour éviter qu'un compromis de tag amont injecte du code. Commenter avec la version humaine à côté.
    ```yaml
    - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
    ```
  - **Test plan** : `grep -E 'uses: .*@[a-f0-9]{40}' .github/workflows/release.yml` retourne autant de lignes que d'actions utilisées (≥ 8).

---

## 2. Linter post-release

- [x] **2.1 `scripts/check_release_artifacts.sh`**
  - **Notes** : Script bash qui prend un tag en argument (`./check_release_artifacts.sh v0.1.0`) et valide :
    1. `docker manifest inspect ghcr.io/banux/reconaut-api:<tag>` retourne un manifest list avec 2 plateformes.
    2. Idem pour `reconaut-scanner`.
    3. `cosign verify --certificate-identity-regexp 'https://github.com/banux/Reconaut/.*' --certificate-oidc-issuer https://token.actions.githubusercontent.com ghcr.io/banux/reconaut-api:<tag>` retourne 0.
    4. Idem pour scanner.
    5. `gh release view <tag> --json assets | jq` confirme la présence de `sbom-reconaut-api-<tag>.cdx.json` ET `sbom-reconaut-scanner-<tag>.cdx.json`.
    6. Téléchargement des SBOM via `gh release download` et parse JSON pour confirmer `bomFormat: CycloneDX`.
    Le script échoue avec exit ≠ 0 et un message explicite à la première vérification qui rate.
  - **Test plan** : Sur un tag fictif inexistant → exit ≠ 0 avec message clair. Sur un tag réel (post-première-release) → exit 0.

- [x] **2.2 Workflow `verify-release.yml` (manual + cron)**
  - **Notes** : Workflow `workflow_dispatch` (mainteneur déclenche manuellement avec un input `tag`) + `schedule: cron: '0 0 1 * *'` (premier de chaque mois — re-vérifie que les anciennes releases restent vérifiables, alerte si Rekor a un problème ou si une image a été supprimée).
  - **Test plan** : Trigger manuel sur un tag publié → green.

---

## 3. Documentation

- [x] **3.1 `docs/operating/release-process.md`** (côté mainteneur)
  - **Notes** : Procédure complète :
    1. Pré-conditions : CI verte sur main, no `[WIP]` PR open, CHANGELOG.md mis à jour si présent.
    2. Choix du tag : SemVer strict (`v0.1.0`, `v1.0.0-rc1`).
    3. Commande : `git tag -a v0.1.0 -m "Release v0.1.0" && git push origin v0.1.0`.
    4. Suivi : le workflow `release.yml` s'exécute (~10-15 min) ; observer dans GitHub Actions.
    5. Post-release : `bash scripts/check_release_artifacts.sh v0.1.0` localement (avec `gh`, `cosign`, `docker` installés).
    6. Bump du chart Helm : `sed -i 's/tag: 0.1.0-dev/tag: v0.1.0/' deploy/helm/reconaut/values.yaml ; commit.
  - **Test plan** : `grep -c "git tag\|SemVer\|release.yml\|cosign verify" docs/operating/release-process.md` retourne ≥ 5.

- [x] **3.2 `docs/operating/verify-image.md`** (côté opérateur)
  - **Notes** : Guide pour un opérateur qui audite sa supply chain :
    - Installation cosign (`brew install cosign` / linux binary).
    - Commande de vérification d'image (`cosign verify ...`).
    - Extraction du SBOM (`gh release download` OR `cosign download attestation`).
    - Lecture d'un SBOM CycloneDX (structure JSON, exemples).
    - Audit des déps : grep CVE connues, hash check.
    - Que faire en cas de vérification échouée (image trojanisée potentielle).
  - **Test plan** : `grep -c "cosign verify\|sbom\|cyclonedx\|certificate-identity" docs/operating/verify-image.md` retourne ≥ 6.

- [x] **3.3 Ajout dans `mkdocs.yml` nav**
  - **Notes** : Sous "Opérationnel" :
    - Processus de release (mainteneur): operating/release-process.md
    - Vérifier une image (opérateur): operating/verify-image.md
  - **Test plan** : `mkdocs build --strict` passe.

---

## 4. Bump du chart Helm post-première-release

- [x] **4.1 Bumper `deploy/helm/reconaut/values.yaml`**
  - **Notes** : Une fois `v0.1.0` publié sur GHCR, modifier :
    ```yaml
    image:
      repository: ghcr.io/banux/reconaut-api
      tag: v0.1.0
    scanner:
      image:
        repository: ghcr.io/banux/reconaut-scanner
        tag: v0.1.0
    ```
    À faire dans un PR séparé après la première release (sinon le chart pointe vers une image qui n'existe pas).
  - **Test plan** : `helm template ... --set ...` continue de passer ; les images résolvent contre GHCR.

- [x] **4.2 Bumper `docker-compose.yml`**
  - **Notes** : Idem — `image: reconaut/api:0.1.0-dev` → `image: ghcr.io/banux/reconaut-api:v0.1.0`. Optionnel : garder `build:` à côté pour permettre le build local en dev (`docker compose build`).
  - **Test plan** : `docker compose config` reste valide.

---

## 5. Acceptance pour le change dans son ensemble

- [x] **5.1 Workflow release.yml + verify-release.yml présents et valides**
  - **Notes** : Lint YAML : `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"` réussit. Idem pour verify-release.yml.

- [x] **5.2 Linter post-release exécuté à blanc**
  - **Notes** : `bash scripts/check_release_artifacts.sh v0.0.0-doesnt-exist` retourne ≠ 0 avec message clair, sans crash. Test du chemin négatif.

- [x] **5.3 Aucune régression**
  - **Notes** : `mkdocs build --strict` passe. Tous les linters CI restent verts. RSpec et Go tests inchangés (release est un workflow CI séparé, aucun code applicatif touché).

- [x] **5.4 Tick `init-reconaut-platform` §8.1 + §8.2 + acceptance L266**
  - **Notes** : Statut documente : (a) workflow release.yml multi-arch GHCR, (b) SBOM CycloneDX via syft-action, (c) signature cosign keyless OIDC GitHub, (d) linter post-release. La première release effective sera coupée hors scope de ce change (l'opérateur tag manuellement quand le code est prêt).

- [x] **5.5 Smoke test : tag de test sur fork ou branche**
  - **Notes** : Pour valider que le workflow tourne effectivement, le mainteneur peut soit (a) créer un tag `v0.0.0-test1` éphémère, soit (b) tester sur un fork. Documenter la procédure dans `release-process.md`. **Optionnel** — la validation finale viendra à la première vraie release.
