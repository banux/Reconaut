# Change : add-helm-chart

## Pourquoi

`init-reconaut-platform` §8.3 demande un *chart Helm sous `deploy/helm/reconaut`* avec valeurs par défaut sécurisées **et** un *docker-compose.yml de référence* qui démarre la stack complète (Postgres + Rails + scanner Go) avec un healthcheck `/healthz` 200 en moins de 60 s. Aujourd'hui, le `docker-compose.yml` racine ne contient **que Postgres** ; il n'y a ni Dockerfile pour Rails ou scanner, ni chart Helm.

Trois trous concrets que ce change ferme :

1. **Pas de déploiement reproductible.** Un opérateur qui veut tester Reconaut doit (a) cloner le repo, (b) installer Ruby 3.4 + Go 1.23 + Postgres + extensions (TimescaleDB, pgvector, AGE), (c) lancer 7+ processus à la main (Rails server, GoodJob worker, 6 scanner-workers, Postgres). Pas de chemin "docker compose up -d" qui marche.
2. **Pas de chart Helm.** Pour un déploiement Kubernetes (cas d'usage RTC entreprise / lab interne), il faut écrire des manifests à la main. Aucune référence officielle.
3. **Acceptance line 252** d'init (*Une instance auto-hébergée démarre via `docker compose up -d` sans aucune clé API externe configurée et reste pleinement fonctionnelle*) est bloquée par §8.3 — ce change la débloque.

Pour rendre §8.3 actionnable, ce change doit aussi livrer **les Dockerfiles minimaux** pour `apps/api/` et `apps/scanner/`. Ce sont des Dockerfiles simples (single-arch, unsigned) ; le hardening multi-arch + SBOM + Sigstore relève de `add-oci-release` (§8.1/§8.2) — séparé et out-of-scope ici.

## Ce qui change

1. **Dockerfiles minimaux** :
   - `apps/api/Dockerfile` : base `ruby:3.4-slim`, install build deps (libpq, build-essential), `bundle install`, copy app, expose 3000, CMD `bundle exec rails server -b 0.0.0.0`.
   - `apps/scanner/Dockerfile` : multi-stage `golang:1.26-alpine` → `gcr.io/distroless/static-debian12`. Build chaque binaire `scanner-<kind>` ; entrypoint paramétrable via `RECONAUT_SCAN_KIND` env var.
   - Pas de tag multi-arch, pas de signing — différé à `add-oci-release`.

2. **`docker-compose.yml` étendu** : ajoute les services `api` (Rails) et 6 services `scanner-<kind>` (un par scan_kind), tous reliés à `postgres`. Healthchecks. Variables d'env par défaut sécurisées (embedder local, TLS optional pour dev). Volumes partagés pour les exports.

3. **`docker-compose.override.yml.example`** : override opt-in pour brancher Ollama en sidecar local. Documente comment activer un embedder externe sans toucher au compose principal.

4. **Chart Helm `deploy/helm/reconaut/`** :
   - `Chart.yaml`, `values.yaml`, `README.md`, `.helmignore`.
   - Templates : `deployment-api.yaml`, `deployment-scanner-<kind>.yaml` (boucle Helm sur la liste des scan_kinds), `service-api.yaml`, `configmap.yaml`, `secret.yaml`, `serviceaccount.yaml`, `_helpers.tpl`.
   - Optionnel via values : `ingress.yaml`, `networkpolicy.yaml`, `job-bootstrap.yaml` (Helm hook qui lance `rails reconaut:set_password`).
   - **Postgres externe par défaut** : l'opérateur fournit `postgres.url` ou `postgres.host`+`postgres.password`. Pas de subchart bitnami imposé — on documente comment l'ajouter en option.
   - **Defaults sécurisés** : `embedder.provider=local`, `mcp.tlsRequired=true`, `ingress.enabled=false`, `networkPolicy.enabled=false` (off par défaut, opt-in pour air-gapped).

5. **Linter `scripts/check_helm_chart.sh`** : exécute `helm lint deploy/helm/reconaut` et `helm template ... | kubectl apply --dry-run=client -f -` (si `helm` et `kubectl` sont dispos). Sinon, fallback : valide la structure YAML statiquement (chaque `templates/*.yaml` parse OK).

6. **Documentation** :
   - `docs/operating/deployment-helm.md` : guide opérateur pour déployer en k8s. Variables clefs, sécurité (NetworkPolicy), bootstrap initial.
   - `docs/operating/deployment-docker-compose.md` : guide pour le déploiement local/simple via docker compose. Build des images, healthcheck, override Ollama.

## Contraintes

- **Pas de Redis / RabbitMQ / NATS / Kafka** dans le compose ni le chart. Cohérent avec project.md (`check_stack.sh` rejette les brokers externes). GoodJob backed-by-Postgres reste l'unique file.
- **Pas de MinIO / S3**. Les exports (`tmp/exports/`) sont sur le filesystem du container Rails, persisté via PVC en k8s ou volume Docker en dev.
- **Pas d'Ollama imposé**. L'embedder local (zéro réseau) est le défaut. Ollama est un override opt-in (compose.override.yml.example) pour les opérateurs qui veulent un meilleur modèle.
- **Pas d'image `reconaut/api:latest` publique**. Ce change livre les Dockerfiles ; la publication d'images (registry, multi-arch, signing) relève de `add-oci-release`. Le compose et le chart utilisent `image: reconaut/api:dev` qui doit être buildé localement (`docker compose build`) ou pulled depuis un registry privé après `add-oci-release`.
- **`check_stack.sh` reste vert**. Le compose n'introduit ni broker externe, ni S3, ni tenant_id. Le chart non plus.
- **AGPL clean**. Pas de gem ou package introduits ; les Dockerfiles utilisent des base images officielles (ruby, golang, distroless) sous licences ouvertes.
- **Mode mono-user respecté**. Le bootstrap Helm hook crée UN user opérateur (`reconaut:set_password`) ; pas de notion de tenant.
- **Pas de subchart obligatoire**. Le chart Reconaut ne dépend pas de bitnami/postgresql par défaut — l'opérateur câble sa propre instance Postgres (BYO). Une section README documente comment ajouter le subchart si désiré, sans le rendre obligatoire.

## Non-objectifs (hors scope de ce change)

- **Images OCI multi-arch + SBOM + Sigstore signing** — relève de `add-oci-release`. Les Dockerfiles livrés ici sont simples (single-arch local build).
- **Subchart Postgres bitnami obligatoire** — laissé optionnel ; l'opérateur BYO.
- **Subchart Ollama** — l'embedder local par défaut suffit pour démarrer ; Ollama vit dans un override opt-in.
- **Operator k8s pattern** (Reconaut CRD) — hors scope.
- **Helm hook complet de migration de DB** — la migration `rails db:migrate` est lancée par un init container ou un job pre-install ; pas de mécanisme custom de migration progressive.
- **Cert-manager intégration** — l'ingress documente comment activer TLS via cert-manager mais ne l'impose pas.
- **Test e2e Kubernetes** — exige un cluster minikube/kind en CI, gros chantier ; relève de `add-helm-e2e-test` futur.
- **Charts pour Grafana / Prometheus / OTel collector** — l'observabilité externe relève de `add-otel-instrumentation`.
- **Auto-scaling HPA** — pas en v1 ; un opérateur peut l'ajouter via patch.

## Décisions prises

1. **BYO Postgres par défaut**. Forcer un subchart Postgres rend l'install plus lourde et masque le fait que Postgres en prod doit être correctement configuré (backup, HA, monitoring). En documentant que l'opérateur fournit son cluster, on évite de fausses garanties.
2. **6 Deployments scanner séparés** (un par scan_kind) plutôt qu'un seul scaling fluide. Cohérent avec `replace-web-with-tui` §3.1 (*Workers de scan spécialisés*) — la spécialisation par binaire est un invariant.
3. **Helm hook `pre-install` pour bootstrap**. Le Job `reconaut-bootstrap` exécute `rails db:migrate` puis `rails reconaut:set_password` (lit `RECONAUT_OPERATOR_PASSWORD` depuis le Secret). Cohérent avec `add-persistent-auth-storage` §5.2.
4. **NetworkPolicy off par défaut**. Activable via `values.networkPolicy.enabled=true`. En air-gapped (cf. init §8.5), l'opérateur active la NetworkPolicy qui bloque l'egress sauf vers `postgres` et `ollama` (si présent). Off par défaut pour ne pas casser les déploiements basiques.
5. **`docker-compose.override.yml.example`** plutôt qu'un profile compose. Plus explicite (le contributeur doit copier le fichier pour activer Ollama), plus pédagogique.
6. **Pas d'image `latest`** dans le chart values.yaml. Le tag par défaut est figé à une version (`reconaut/api:0.1.0-dev`). Évite les déploiements involontaires qui pull `latest` à chaque restart.

## Différé (non bloquant, parqué pour plus tard)

- **`add-oci-release`** : images multi-arch (amd64+arm64), SBOM CycloneDX, signature Sigstore/cosign — couvre §8.1/§8.2.
- **`add-helm-e2e-test`** : test e2e Kubernetes via kind/minikube en CI.
- **`add-helm-postgres-subchart`** : optionnel — subchart bitnami/postgresql avec backup intégré.
- **`add-cert-manager-integration`** : annotations + Issuer pour certificats automatiques.
- **`add-helm-monitoring`** : ServiceMonitor Prometheus + dashboards Grafana embarqués.
- **`add-helm-backup`** : CronJob qui dump Postgres vers un PVC ou un bucket configurable.
- **`add-reconaut-operator`** : pattern Operator k8s avec CRD `Reconaut`.
