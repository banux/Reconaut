# Tâches : add-helm-chart

Checklist de la livraison du chart Helm + docker-compose étendu + Dockerfiles minimaux. L'objectif est de débloquer §8.3 d'init-reconaut-platform sans déborder sur §8.1 (multi-arch + signing → `add-oci-release`).

---

## 1. Dockerfiles minimaux

- [x] **1.1 `apps/api/Dockerfile`**
  - **Notes** : Image base `ruby:3.4-slim`. Layers : (a) install build deps (libpq-dev, build-essential, git, postgresql-client), (b) `WORKDIR /app`, (c) copy `Gemfile + Gemfile.lock`, `bundle install --jobs 4 --retry 3`, (d) copy le reste du code, (e) `RUN bundle exec bootsnap precompile --gemfile app/ lib/` pour accélérer le boot, (f) `EXPOSE 3000`, (g) `ENV RAILS_ENV=production`, (h) `CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]`.
  - **Test plan** : `docker build -t reconaut/api:dev apps/api/` réussit. Image taille raisonnable (< 1 GB).

- [x] **1.2 `apps/scanner/Dockerfile`**
  - **Notes** : Multi-stage. Stage 1 (`golang:1.26-alpine`) : `WORKDIR /src`, `COPY apps/scanner/`, `RUN for kind in tcp_probe tls_capture http_banner subdomain_enum service_fingerprint dns_records; do CGO_ENABLED=0 go build -o /out/scanner-$kind ./cmd/scanner-$kind/; done`. Stage 2 (`gcr.io/distroless/static-debian12`) : copy `/out/*` → `/usr/local/bin/`, ENTRYPOINT script qui dispatche selon `RECONAUT_SCAN_KIND` env var (`exec /usr/local/bin/scanner-$RECONAUT_SCAN_KIND`).
  - **Test plan** : `docker build -t reconaut/scanner:dev apps/scanner/` réussit. `docker run -e RECONAUT_SCAN_KIND=tcp_probe reconaut/scanner:dev --version` imprime la version.

---

## 2. docker-compose.yml étendu

- [x] **2.1 Ajouter service `api`**
  - **Notes** : Sous `services:` ajouter `api` :
    ```yaml
    api:
      build: ./apps/api
      image: reconaut/api:dev
      container_name: reconaut-api
      depends_on:
        postgres: { condition: service_healthy }
      environment:
        RAILS_ENV: production
        RECONAUT_DATABASE_URL: postgresql://reconaut:reconaut_dev_password@postgres:5432/reconaut_development
        RECONAUT_OPERATOR_PASSWORD: changeme
        RECONAUT_EMBEDDER_PROVIDER: local
        RECONAUT_MCP_TLS_REQUIRED: "false"  # dev local sans TLS
      volumes:
        - exports_data:/app/tmp/exports
      ports:
        - "127.0.0.1:3000:3000"
      healthcheck:
        test: ["CMD-SHELL", "curl -fsS http://localhost:3000/healthz || exit 1"]
        interval: 5s
        timeout: 5s
        retries: 30
    ```
  - **Test plan** : `docker compose up -d postgres api` puis `curl -fsS http://localhost:3000/healthz` répond 200 en < 60 s.

- [x] **2.2 Ajouter 6 services scanner-<kind>**
  - **Notes** : Boucle YAML pour les 6 kinds. Chaque service partage la même image `reconaut/scanner:dev` avec `RECONAUT_SCAN_KIND` distinct.
    ```yaml
    scanner-tcp_probe:
      build: ./apps/scanner
      image: reconaut/scanner:dev
      depends_on:
        postgres: { condition: service_healthy }
      environment:
        RECONAUT_SCAN_KIND: tcp_probe
        RECONAUT_DATABASE_URL: postgresql://reconaut:reconaut_dev_password@postgres:5432/reconaut_development
      restart: unless-stopped
    # idem pour tls_capture, http_banner, subdomain_enum, service_fingerprint, dns_records
    ```
  - **Test plan** : `docker compose ps` montre les 6 scanners en `running` ; `docker compose logs scanner-tcp_probe` affiche le démarrage du worker.

- [x] **2.3 `docker-compose.override.yml.example` (Ollama opt-in)**
  - **Notes** : Fichier exemple :
    ```yaml
    # Copier en docker-compose.override.yml pour activer Ollama.
    services:
      ollama:
        image: ollama/ollama:latest
        container_name: reconaut-ollama
        volumes: [ollama_data:/root/.ollama]
        ports: ["127.0.0.1:11434:11434"]
      api:
        environment:
          RECONAUT_EMBEDDER_PROVIDER: ollama
          RECONAUT_EMBEDDER_OLLAMA_URL: http://ollama:11434
          RECONAUT_EMBEDDER_OLLAMA_MODEL: nomic-embed-text
    volumes:
      ollama_data:
    ```
  - **Test plan** : `cp docker-compose.override.yml.example docker-compose.override.yml && docker compose up -d` ; le service `ollama` apparaît et l'API utilise l'embedder ollama (vérifiable via `reconaut:doctor`).

---

## 3. Helm chart `deploy/helm/reconaut/`

- [x] **3.1 `Chart.yaml`**
  - **Notes** :
    ```yaml
    apiVersion: v2
    name: reconaut
    description: Base de connaissance d'actifs internet pour agents IA, scope-driven, AGPL-3.0
    type: application
    version: 0.1.0
    appVersion: "0.1.0"
    home: https://github.com/banux/Reconaut
    sources: [https://github.com/banux/Reconaut]
    keywords: [asm, security, mcp, knowledge-base, agpl]
    maintainers:
      - name: banux
    ```
  - **Test plan** : `helm lint deploy/helm/reconaut` exit 0.

- [x] **3.2 `values.yaml` defaults sécurisés**
  - **Notes** : Structure :
    ```yaml
    image:
      repository: reconaut/api
      tag: 0.1.0-dev   # pas latest
      pullPolicy: IfNotPresent
    scanner:
      image: { repository: reconaut/scanner, tag: 0.1.0-dev }
      kinds: [tcp_probe, tls_capture, http_banner, subdomain_enum, service_fingerprint, dns_records]
      replicas: 1  # par kind

    postgres:
      external: true   # BYO par défaut
      url: ""          # ex: postgresql://user:pass@host:5432/db

    embedder:
      provider: local  # local | ollama | mistral | openai-compatible

    mcp:
      tlsRequired: true

    auth:
      bootstrap:
        enabled: true
        operatorPassword: ""  # injecté via Secret

    ingress:
      enabled: false
      className: ""
      hosts: []

    networkPolicy:
      enabled: false

    serviceAccount:
      create: true

    resources:
      api: { requests: { cpu: 100m, memory: 256Mi } }
      scanner: { requests: { cpu: 50m, memory: 128Mi } }
    ```
  - **Test plan** : `helm template reconaut deploy/helm/reconaut --set postgres.url=postgresql://t:t@t/t` produit un manifest valide.

- [x] **3.3 Templates : Deployment API + 6 scanner deployments**
  - **Notes** :
    - `templates/_helpers.tpl` : `reconaut.fullname`, `reconaut.labels`, `reconaut.commonEnv` (envvars partagées).
    - `templates/deployment-api.yaml` : Deployment `{{ include "reconaut.fullname" . }}-api`, container Rails, probes `/healthz`.
    - `templates/deployment-scanner.yaml` : boucle Helm `{{- range .Values.scanner.kinds }}` qui génère 1 Deployment par kind.
  - **Test plan** : `helm template ... | grep -c "kind: Deployment"` retourne 7 (1 API + 6 scanners).

- [x] **3.4 Templates : Service, ConfigMap, Secret, ServiceAccount**
  - **Notes** :
    - `templates/service-api.yaml` : ClusterIP, port 3000.
    - `templates/configmap.yaml` : variables non sensibles (provider embedder, posture TLS, scope, etc.).
    - `templates/secret.yaml` : `RECONAUT_OPERATOR_PASSWORD`, `RECONAUT_DATABASE_URL`. Généré depuis `values.auth.bootstrap.operatorPassword` + `values.postgres.url`.
    - `templates/serviceaccount.yaml` : ServiceAccount `{{ include "reconaut.fullname" . }}` (créé si `serviceAccount.create=true`).
  - **Test plan** : Chacune des ressources apparaît dans `helm template`.

- [x] **3.5 Templates : Ingress + NetworkPolicy + Bootstrap Job**
  - **Notes** :
    - `templates/ingress.yaml` : conditionnel `{{- if .Values.ingress.enabled }}` ; permet d'exposer `api` si l'opérateur le veut.
    - `templates/networkpolicy.yaml` : conditionnel `{{- if .Values.networkPolicy.enabled }}` ; restreint l'egress aux services internes (postgres, ollama si présent, DNS k8s).
    - `templates/job-bootstrap.yaml` : Helm hook `pre-install,pre-upgrade` qui exécute `bundle exec rails db:migrate && bundle exec rails reconaut:set_password`. Idempotent (skip si user existe déjà sauf `RECONAUT_ROTATE`).
  - **Test plan** : `helm template ... --set ingress.enabled=true --set networkPolicy.enabled=true` produit un Ingress et une NetworkPolicy. `helm template ... --set auth.bootstrap.enabled=true` produit un Job avec annotation `helm.sh/hook: pre-install,pre-upgrade`.

- [x] **3.6 README chart**
  - **Notes** : `deploy/helm/reconaut/README.md` documente : installation (`helm install`), configuration (variables principales), bootstrap initial, options avancées (NetworkPolicy, Ingress, Ollama sidecar via override values.yaml), troubleshooting (404 healthz, password rotation).
  - **Test plan** : `grep -c "helm install\|values\|bootstrap" deploy/helm/reconaut/README.md` retourne ≥ 5.

---

## 4. Linter `check_helm_chart.sh`

- [x] **4.1 Script `scripts/check_helm_chart.sh`**
  - **Notes** : Si `helm` est dans PATH : `helm lint deploy/helm/reconaut` puis `helm template reconaut deploy/helm/reconaut --set postgres.url=postgresql://t/t` (capture stdout). Si `kubectl` est dispo : pipe vers `kubectl apply --dry-run=client -f -`. Sinon, simple validation YAML statique : pour chaque `deploy/helm/reconaut/templates/*.yaml`, vérifier que le contenu Go template extrait (sans rendre) parse en YAML valide.
    - Sans `helm` : log `helm not installed - skipping deep validation` et tente la validation YAML statique des templates non-rendus.
  - **Test plan** : Sur le chart livré → exit 0. Test : injecter `{{ .Values.nonexistent }}` sans default dans un template → exit ≠ 0 si helm est dispo.

- [x] **4.2 Test du linter `scripts/check_helm_chart_test.sh`**
  - **Notes** : Cas (a) état clean → exit 0, (b) injecter un `{{ required "missing" .Values.foo }}` non fourni → exit ≠ 0 (si helm dispo, sinon test skipped), (c) cleanup.
  - **Test plan** : Sur le tree clean → exit 0.

- [x] **4.3 Wiring CI**
  - **Notes** : Ajouter au job `stack-lint` les steps `bash scripts/check_helm_chart.sh` + `bash scripts/check_helm_chart_test.sh`. Optionnellement, ajouter une step `azure/setup-helm@v4` avant pour s'assurer que helm est dispo en CI.
  - **Test plan** : Le job stack-lint passe vert avec helm installé.

---

## 5. Documentation

- [x] **5.1 `docs/operating/deployment-helm.md`**
  - **Notes** : Guide opérateur : prérequis (k8s 1.27+, Postgres 16+ avec extensions), commande d'install, variables clefs, sécurité (NetworkPolicy + Ingress TLS), bootstrap initial, mise à jour, désinstallation propre.
  - **Test plan** : `grep -c "helm install\|values\|bootstrap" docs/operating/deployment-helm.md` retourne ≥ 5.

- [x] **5.2 `docs/operating/deployment-docker-compose.md`**
  - **Notes** : Guide pour le déploiement local/simple : prérequis (Docker 24+), commandes `docker compose build && docker compose up -d`, healthcheck, accès aux logs, override Ollama opt-in, persistance des volumes, sauvegarde Postgres.
  - **Test plan** : `grep -c "docker compose\|healthz\|ollama" docs/operating/deployment-docker-compose.md` retourne ≥ 4.

- [x] **5.3 Ajout dans `mkdocs.yml` nav**
  - **Notes** : Sous "Opérationnel" :
    ```yaml
    - Déploiement (Helm): operating/deployment-helm.md
    - Déploiement (docker-compose): operating/deployment-docker-compose.md
    ```
  - **Test plan** : `mkdocs build --strict` passe.

---

## 6. Acceptance pour le change dans son ensemble

- [x] **6.1 `helm lint` + `helm template` passent**
  - Exécuter manuellement (ou via le script). Le manifest produit est consommable par `kubectl apply --dry-run=client`. 7 Deployments, 1 Service, 1 ConfigMap, 1 Secret, 1 ServiceAccount, 1 Job (bootstrap).

- [x] **6.2 `docker compose up -d` démarre la stack**
  - Sur une machine avec Docker, `docker compose build && docker compose up -d`. En moins de 60 s, `curl -fsS http://localhost:3000/healthz` retourne 200.

- [x] **6.3 Aucune régression**
  - Toute la suite RSpec actuelle (534 examples avant ce change) reste verte. Tous les linters CI restent verts (y compris le nouveau `check_helm_chart.sh`).

- [x] **6.4 Tick `init-reconaut-platform` §8.3 ET acceptance line 252**
  - Le statut documenté pour §8.3 mentionne : (a) chart Helm livré sous `deploy/helm/reconaut/`, (b) docker-compose étendu avec API + 6 scanners, (c) Ollama opt-in via override, (d) linter `check_helm_chart.sh` wired in CI, (e) docs opérateur. La ligne 252 (instance auto-hébergée via docker compose up sans clé externe) devient tickable une fois le déploiement local validé.
