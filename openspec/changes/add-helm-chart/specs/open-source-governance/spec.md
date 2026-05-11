# Spec delta : open-source-governance

## ADDED Requirements

### Requirement: Reference Helm Chart
La plateforme DOIT exposer un chart Helm sous `deploy/helm/reconaut/` qui permet le déploiement de Reconaut sur un cluster Kubernetes avec des valeurs par défaut sécurisées (embedder local, TLS exigé, pas d'OIDC, NetworkPolicy off mais activable).

Le chart DOIT respecter ces contraintes :

- **Conforme à Helm 3** : `apiVersion: v2`, fichiers `Chart.yaml` + `values.yaml` + `templates/` standard.
- **`helm lint deploy/helm/reconaut`** retourne exit 0 sans erreur.
- **`helm template`** produit un manifest valide YAML que `kubectl apply --dry-run=client` accepte.
- **Mono-user enforcé** : pas de paramètre `tenant_id` ni de support multi-tenant dans les values.
- **Defaults sécurisés** :
  - `embedder.provider=local` (zéro réseau sortant)
  - `mcp.tlsRequired=true`
  - `ingress.enabled=false` (l'opérateur ouvre explicitement)
  - `networkPolicy.enabled=false` (off par défaut, opt-in pour air-gapped)
- **Postgres BYO** : pas de subchart Postgres imposé. L'opérateur fournit `postgres.url` ou `postgres.host`+`postgres.password` via values. Un subchart bitnami/postgresql est documenté en option dans le README mais pas activé.
- **6 Deployments scanner-<kind>** séparés (un par scan_kind : `tcp_probe`, `tls_capture`, `http_banner`, `subdomain_enum`, `service_fingerprint`, `dns_records`).
- **Bootstrap via Helm hook** : un Job `pre-install`/`pre-upgrade` exécute `rails db:migrate` puis `rails reconaut:set_password` en lisant `RECONAUT_OPERATOR_PASSWORD` depuis le Secret généré.

#### Scenario: helm lint passe sur le chart livré
- **GIVEN** le chart sous `deploy/helm/reconaut/` dans son état committed
- **WHEN** `helm lint deploy/helm/reconaut` est exécuté
- **THEN** exit code 0
- **AND** aucune erreur ni warning critique signalé

#### Scenario: helm template + kubectl apply --dry-run accepte le manifest
- **GIVEN** le chart par défaut
- **WHEN** `helm template reconaut deploy/helm/reconaut --set postgres.url=postgresql://test/test | kubectl apply --dry-run=client -f -` est exécuté
- **THEN** `kubectl` accepte chaque ressource (Deployment, Service, ConfigMap, Secret, ServiceAccount)
- **AND** aucune ressource ne contient `tenant_id` ou un autre marqueur multi-tenant

#### Scenario: Defaults respectent l'embedder local
- **GIVEN** un déploiement helm avec values par défaut
- **WHEN** on inspecte le ConfigMap rendu
- **THEN** `RECONAUT_EMBEDDER_PROVIDER=local`
- **AND** `RECONAUT_MCP_TLS_REQUIRED=true`
- **AND** aucune variable embedder pointant vers un endpoint externe (pas de `RECONAUT_EMBEDDER_OLLAMA_URL` valorisée par défaut)

#### Scenario: NetworkPolicy opt-in
- **GIVEN** values.networkPolicy.enabled=true
- **WHEN** `helm template ...` est exécuté
- **THEN** un objet `NetworkPolicy` apparaît dans le manifest
- **AND** sa règle d'egress autorise UNIQUEMENT (a) le DNS interne k8s, (b) le service postgres référencé, (c) l'éventuel sidecar ollama si values.embedder.provider=ollama

#### Scenario: Bootstrap hook crée l'opérateur unique
- **GIVEN** un déploiement helm fresh sur un Postgres vierge
- **WHEN** la phase `pre-install` exécute le Job de bootstrap
- **THEN** la table `users` contient une seule ligne (l'opérateur)
- **AND** la table `api_keys` contient au moins une ligne (la clé bootstrap)
- **AND** un re-install sans `RECONAUT_ROTATE=true` lève `bootstrap-already-initialized`

### Requirement: Reference docker-compose Stack
La plateforme DOIT exposer un `docker-compose.yml` racine qui démarre la stack complète (Postgres + Rails API + 6 scanner workers Go) avec un healthcheck `/healthz` qui répond 200 en moins de 60 secondes après `docker compose up -d`.

Contraintes :

- **Pas de Redis / RabbitMQ / NATS / Kafka** dans les services.
- **Pas de MinIO / S3** ; les exports vivent dans un volume Docker partagé.
- **Pas d'Ollama imposé** ; un fichier `docker-compose.override.yml.example` fourni montre comment l'activer.
- **Healthcheck Rails** : `curl -fsS http://localhost:3000/healthz` retourne 200.
- **Variables par défaut sécurisées** (cf. chart Helm).

#### Scenario: docker compose up -d démarre la stack
- **GIVEN** un repo dans son état committed avec les images locales buildées (`docker compose build`)
- **WHEN** `docker compose up -d` est exécuté
- **THEN** les conteneurs `postgres`, `api`, `scanner-tcp_probe`, `scanner-tls_capture`, `scanner-http_banner`, `scanner-subdomain_enum`, `scanner-service_fingerprint`, `scanner-dns_records` sont en `running` healthy
- **AND** dans les 60 secondes, `curl -fsS http://localhost:3000/healthz` retourne HTTP 200

#### Scenario: Aucun broker externe dans le compose
- **GIVEN** le `docker-compose.yml` committed
- **WHEN** on grep `redis|rabbitmq|nats|kafka` dans le fichier
- **THEN** **aucune** correspondance dans une déclaration `image:` ou `service:`
- **AND** `bash scripts/check_stack.sh` reste vert

#### Scenario: Override Ollama opt-in
- **GIVEN** le fichier `docker-compose.override.yml.example`
- **WHEN** un opérateur le copie en `docker-compose.override.yml` et lance `docker compose up -d`
- **THEN** un service `ollama` démarre en plus
- **AND** les variables `RECONAUT_EMBEDDER_PROVIDER=ollama` + `RECONAUT_EMBEDDER_OLLAMA_URL=http://ollama:11434` sont injectées dans le service `api`

### Requirement: Helm Chart Linter
La plateforme DOIT inclure un script `scripts/check_helm_chart.sh` qui valide le chart Helm via `helm lint` et `helm template + kubectl --dry-run`. Le script DOIT être wired dans le job CI `stack-lint`.

#### Scenario: Linter passe sur le chart livré
- **GIVEN** le chart `deploy/helm/reconaut/` dans son état committed
- **WHEN** `bash scripts/check_helm_chart.sh` est exécuté (avec `helm` installé)
- **THEN** exit code 0
- **AND** un test `scripts/check_helm_chart_test.sh` injecte temporairement une erreur de templating (variable indéfinie) et confirme que le linter échoue

#### Scenario: Linter graceful sans helm CLI
- **GIVEN** un environnement sans `helm` CLI installé
- **WHEN** `bash scripts/check_helm_chart.sh` est exécuté
- **THEN** le script log un warning `helm not installed - skipping deep validation`
- **AND** retombe sur une validation YAML statique : chaque `templates/*.yaml` parse en YAML valide
- **AND** retourne exit 0 (le linter ne casse pas la build des contributeurs sans helm)
