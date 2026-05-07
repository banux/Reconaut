# Tâches : add-tech-stack

Checklist d'adoption de la stack Vue 3 + Vite + Rails 8 + Go + GoodJob. Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Documentation et alignement de contexte

- [x] **1.1 `openspec/project.md` figé sur la stack** (déjà fait dans ce change)
  - **Notes** : Section *Stack* mise à jour : Vue 3 + Vite, Rails 8, Go (workers), GoodJob (file Postgres-backed), embedder pluggable via env, Postgres unique avec TimescaleDB + pgvector + AGE, pas de stockage objet, auth local-first.

- [ ] **1.2 Aligner les notes d'implémentation de `init-reconaut-platform/tasks.md`**
  - **Notes** : Réécrire les *Notes* et *Test plan* pour refléter Rails 8 (RSpec, Sorbet/`rbs` si retenu, ActiveRecord, gem `circuit_box` ou équivalent, gem DNS) et Go (`go test`, `golangci-lint`, `go test -bench`, sondeurs en Go pur). Ne pas toucher aux spec deltas (qui sont implementation-agnostiques).
  - **Test plan** : `grep -RniE "fastapi|aiohttp|sqlmodel|uv run|pyproject|cargo|clippy|criterion|rust" openspec/changes/init-reconaut-platform/tasks.md` ne renvoie aucune occurrence ; chaque ancienne mention Python ou Rust a un remplacement Rails ou Go avec sa contrepartie d'outillage de test.

---

## 2. Bootstrap monorepo conforme à la stack — spec : `architecture`

- [x] **2.1 Layout monorepo Rails + Vue + Go**
  - **Notes** : Structure cible :
    - `apps/api/` : Rails 8 monolithe (API, agent, MCP, audit). MCP exposé sous une route Rails (par ex. `mount Mcp::Engine, at: "/mcp"`) dans le même process.
    - `apps/web/` : Vue 3 + Vite, dossier indépendant, déploiement statique servi par Rails (asset pipeline) ou par un reverse proxy.
    - `apps/scanner/` : workspace Go modules avec un binaire `scanner-worker` et un package `scanprotocols` réutilisable.
    - `packages/job-schema/` : définitions de schéma de message (JSON Schema canonique), versionnées, consommées à la fois par Rails (parsing/validation JSON) et par Go (génération de structs via `go-jsonschema` ou équivalent).
    - `Dockerfile` par app, `docker-compose.yml` racine pour le dev local (Postgres + Rails + scanner — pas de broker externe, GoodJob tape directement dans Postgres).
  - **Test plan** : `bin/setup` racine installe Ruby (via `mise`/`asdf`), Node (pour Vue), Go ; `bin/test` exécute en parallèle `cd apps/api && bundle exec rspec`, `cd apps/web && pnpm test`, `cd apps/scanner && go test ./...` ; chaque suite contient un test smoke trivial qui passe.
  - **Statut** : layout en place, Rails 8 API généré, Vue 3 + Vite généré, module Go avec binaire `scanner-worker`. `bin/test` passe les 3 suites smoke. `bin/setup` build et démarre l'image Postgres dev. Reste : intégrer `packages/job-schema` côté Rails et Go (cf. §3.1), Dockerfile par sous-app (différé tant que la stack runtime n'est pas figée pour la prod).

- [ ] **2.2 Pipeline CI multi-stack (GitHub Actions)**
  - **Notes** : Jobs séparés par app : `api-rubocop`, `api-rspec`, `web-eslint`, `web-vitest`, `scanner-golangci-lint`, `scanner-go-test`, build d'image par app. Cache des dépendances (Bundler, pnpm, Go module cache `~/go/pkg/mod`) keyé par lockfile.
  - **Test plan** : Ouvrir une PR triviale ; tous les jobs verts. Introduire une violation `golangci-lint` dans un package Go et vérifier que `scanner-golangci-lint` échoue ; introduire une violation Rubocop côté Rails et vérifier que `api-rubocop` échoue.

- [ ] **2.3 Linter de stack (rejette les violations de l'exigence `architecture`)**
  - **Notes** : Script CI `scripts/check_stack.sh` qui :
    - rejette tout fichier `.jsx`/`.tsx` ou import `react`/`@angular`/`svelte` dans `apps/web/`,
    - rejette toute gem cliente RPC vers les workers (regex sur `Gemfile.lock` pour les patterns `grpc`, `scanner-client`, etc.),
    - rejette tout import direct de `Socket`/`Net::HTTP`/`OpenSSL::SSL::SSLSocket` dans le code Rails à l'exception d'une allowlist documentée (Postgres, IdP OIDC si configuré, embedder externe si configuré, healthcheck),
    - rejette tout fichier `.py`/`pyproject.toml`/`uv.lock`/`Cargo.toml`/`Cargo.lock` dans le repo (résidu Python ou Rust),
    - rejette toute dépendance d'infrastructure externe pour la file de jobs (regex sur `docker-compose.yml`, `Helm values`, `Gemfile.lock` pour `redis`, `rabbitmq`, `nats`, `kafka` employés comme broker — `redis-rb` reste autorisé pour le cache si nécessaire mais la documentation doit le justifier),
    - rejette toute colonne `tenant_id` dans les migrations Rails ou les schémas Go (modèle tenant unique).
  - **Test plan** : `scripts/check_stack.sh` exécuté à propre passe (exit 0). Tests du linter : créer un fichier `apps/web/src/Bad.jsx` → exit ≠ 0 ; ajouter une migration avec `t.string :tenant_id` → exit ≠ 0 ; ajouter `redis` comme broker dans `docker-compose.yml` → exit ≠ 0.

---

## 3. Contrat de message scan — spec : `architecture`

- [x] **3.1 Schéma de message versionné (`packages/job-schema/`)**
  - **Notes** : Définir au minimum trois schémas — `ScanJobV1`, `ScanResultV1`, `Heartbeat` — avec un champ `schema_version: int`, une `idempotency_key: string`, un `target: { kind, value }`, et un `requested_at: rfc3339`. Format JSON Schema canonique. Côté Rails : validation via `json-schema` gem ou équivalent. Côté Go : génération de structs via `go-jsonschema` ou check via `xeipuuv/gojsonschema` au runtime.
  - **Test plan** : Test de round-trip Rails → Postgres (GoodJob) → Go qui sérialise un `ScanJobV1` côté Rails, le désérialise côté Go, vérifie l'égalité champ par champ. Test négatif : un message avec `schema_version=99` est rejeté côté worker avec une erreur explicite (pas un silent skip).
  - **Statut** : trois schémas (`ScanJobV1`, `ScanResultV1`, `HeartbeatV1`) livrés sous `packages/job-schema/`. Validateur Rails `JobSchema::Registry` (gem `json-schema`, draft-06 forcé pour rester offline-friendly). Validateur Go `internal/jobschema` sans dépendance externe. 13 specs Rails + 9 tests Go couvrent : payload conforme, `schema_version` mauvais, `scan_kind` inconnu, `target.kind` inconnu, champ requis manquant, propriété supplémentaire, statut résultat inconnu, `inflight_jobs` négatif, schéma inconnu, round-trip d'un payload « shape Rails » vers le validateur Go. Le round-trip via la table `good_jobs` reste à câbler quand §3.2 sera fait (job bus Rails ↔ Go).

- [ ] **3.2 `JobBus` côté Rails et consommateur côté Go**
  - **Notes** : Côté Rails, `config.active_job.queue_adapter = :good_job` ; classe `ScanJob < ApplicationJob` ; la couche métier publie via `ScanJob.perform_later(payload)`. Côté Go, package `goodjob` qui fait `SELECT ... FROM good_jobs WHERE finished_at IS NULL AND queue_name = $1 AND scheduled_at <= NOW() FOR UPDATE SKIP LOCKED` puis met à jour `performed_at`/`finished_at`. Optionnel : exploiter `LISTEN good_job` pour réveiller le poller. Tests utilisent une DB Postgres éphémère via `testcontainers-go` côté Go et une DB Rails fixture côté Rails.
  - **Test plan** : Test d'intégration Rails publie 3 jobs ; un worker Go en process les consomme et publie 3 résultats ; Rails reçoit les résultats. Aucun appel HTTP/gRPC sortant n'est observé (mock outbound). Aucun service Redis / RabbitMQ / NATS / Kafka n'est démarré pendant le test.

---

## 4. Intégration MCP dans Rails — spec : `architecture` + `mcp-server`

- [ ] **4.1 Engine Rails dédié au MCP partageant la pile de middlewares**
  - **Notes** : Implémenter `apps/api/engines/mcp` (Rails Engine ou namespace de routes). Les outils `search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report` sont des controllers Rails. Le streaming SSE utilise `ActionController::Live`. La couche d'auth est partagée avec l'API REST (un seul `before_action :authenticate!` qui accepte clé API personnelle ou session OIDC).
  - **Test plan** : Test d'intégration appelle `search_hosts` via MCP et `GET /hosts` via API REST avec la même clé API ; assure que les deux passent par le même journal d'audit (même schéma de ligne, même `key_id`). Test négatif : appel MCP avec une clé révoquée renvoie la même erreur structurée que l'API REST.

- [ ] **4.2 `request_scan` enqueue un job au lieu d'appeler un worker**
  - **Notes** : L'outil `request_scan` ne contient aucune logique de scan ; il valide les paramètres, vérifie le scope (cf. spec `scanning`), écrit une ligne d'audit et appelle `ScanJob.perform_later`. Renvoie immédiatement le `scan_id`.
  - **Test plan** : Test d'intégration appelle `request_scan` avec une cible valide ; assure (a) HTTP 200 et `scan_id` renvoyé en < 100 ms, (b) un job GoodJob est présent dans la table avec une `idempotency_key` dérivée de `(target, requested_at_minute)`, (c) aucun appel sortant vers un worker Go n'a eu lieu.

---

## 5. Worker Go de référence (squelette) — spec : `architecture`

- [ ] **5.1 Squelette de worker consommant GoodJob et persistant un résultat**
  - **Notes** : Package Go `cmd/scanner-worker` qui (a) ouvre une connexion `pgx` au cluster Postgres, (b) loop `SELECT ... FROM good_jobs WHERE finished_at IS NULL AND queue_name = 'scan' FOR UPDATE SKIP LOCKED` (avec `LIMIT 1`), (c) parse `serialized_params` JSON contre `ScanJobV1`, (d) effectue un no-op de scan en v1 (placeholder pour les vrais sondeurs livrés au change `scan-engine`), (e) écrit le résultat en table métier puis update la ligne `good_jobs` avec `finished_at = NOW()`. Idempotence : table de déduplication par `idempotency_key` ou `INSERT ... ON CONFLICT DO NOTHING` côté résultats.
  - **Test plan** : Test d'intégration lance 2 workers Go sur la même DB, enqueue 100 jobs (dont 10 doublons par `idempotency_key`) ; assure que (a) tous les jobs uniques sont traités, (b) les doublons sont détectés et acquittés sans seconde écriture, (c) la charge est répartie (chaque worker traite > 30 % du volume unique).

- [ ] **5.2 Gestion de panique sans contamination**
  - **Notes** : Un panic dans la consommation d'un message ne tue pas le worker entier ; chaque job tourne dans une goroutine avec `recover()`, le job est retried selon la politique GoodJob après N tentatives le job va en `failed_executions`.
  - **Test plan** : Injecter un message qui force un panic dans un sondeur ; assurer que (a) le worker continue de consommer les messages suivants, (b) après 3 tentatives la ligne `good_jobs` correspondante est marquée avec `error` non-null et `finished_at` posé (rangée dans la liste des jobs échoués affichée par le dashboard GoodJob), (c) un compteur Prometheus `scan_worker_panics_total` est incrémenté.

---

## 6. Documentation et runbooks

- [ ] **6.1 Documentation de la frontière Rails ↔ Go**
  - **Notes** : Page de doc interne décrivant le contrat de message, la liste des schémas versionnés, comment ajouter un nouveau type de scan (créer le schéma, le publier dans `packages/job-schema`, implémenter le handler Go, ne JAMAIS le coder côté Rails).
  - **Test plan** : La page existe sous `docs/architecture/scan-frontier.md` et est référencée depuis le README racine.

- [ ] **6.2 Runbook : ajouter ou retirer un worker Go en production**
  - **Notes** : Étapes pour déployer N workers supplémentaires, vérifier qu'ils consomment bien (compteur custom `scan_worker_jobs_claimed_total` côté Go + dashboard GoodJob côté Rails), et les retirer proprement (drain — arrêter d'accepter de nouveaux jobs et finir ceux en cours via signal SIGTERM).
  - **Test plan** : Le runbook existe et a été exécuté manuellement une fois en environnement de staging.

---

## Acceptation pour le change dans son ensemble

- [ ] Chaque exigence du spec delta `architecture` a au moins un test automatisé passant en CI.
- [ ] Le linter de stack (`scripts/check_stack.sh`) tourne en CI sur chaque PR et bloque les fusions qui introduisent React/Angular/Svelte/Nuxt, Rust, un broker externe, une colonne `tenant_id`, ou un client RPC synchrone vers les workers.
- [ ] `openspec/project.md` est cohérent avec la stack figée ; les notes de `init-reconaut-platform/tasks.md` sont alignées sur Rails 8 + Go + GoodJob.
- [ ] Une commande `bin/doctor` (Rake task `rails reconaut:doctor`) imprime : version Rails, version Go embarquée du dernier worker connu, taille de la file `good_jobs` (lignes `finished_at IS NULL`), dernier `schema_version` connu côté Rails et côté Go.
