# Tâches : init-reconaut-platform

Checklist fondatrice. Chaque tâche inclut des notes d'implémentation et un test plan qui doit passer avant de cocher la case.

---

## 1. Bootstrap du projet et gouvernance OSS

- [x] **1.1 Application de la licence AGPL-3.0-only**
  - **Notes** : Décision actée (cf. `proposal.md` §Décisions prises §1) — pas de vocation commerciale, AGPL protège contre la ré-hébergement managé fermé sans réciprocité. Intégrer le texte intégral d'AGPL-3.0 dans `LICENSE` à la racine, ajouter `SPDX-License-Identifier: AGPL-3.0-only` en en-tête de chaque fichier source. Rédiger un ADR court `docs/adr/0001-license.md` qui consigne la décision (contexte, options écartées Apache-2.0/BUSL-1.1, conséquences). Vérifier la compatibilité de licence des dépendances (transitives incluses) — refuser toute dépendance dont la licence est incompatible avec AGPL côté sortie.
  - **Test plan** : `licensee detect .` renvoie `AGPL-3.0-only` ; un check CI échoue si un fichier source n'a pas l'en-tête SPDX attendu ; un audit `bundle-audit` / `go-licenses check` / `pnpm licenses ls` confirme zéro dépendance avec licence incompatible.
  - **Statut partiel** : (a) `LICENSE` AGPL-3.0 complet (661 lignes, texte FSF officiel) à la racine. (b) ADR `docs/adr/0001-license.md` rédigé : contexte, options écartées (Apache-2.0, BUSL-1.1, MIT, AGPL-3.0-or-later), décision finale, conséquences pour opérateurs / SaaS / contributeurs. (c) Audit licence Rails (`license_finder` + `dependency_decisions.yml`) en CI : « All dependencies are approved for use » sur les 95 gemmes (cf. add-graph-retrieval § 9.1). **Reste pour cocher** : (i) headers SPDX `SPDX-License-Identifier: AGPL-3.0-only` par fichier source + check CI, (ii) `go-licenses check` côté apps/scanner (différé : pas encore de dépendances Go externes hors stdlib), (iii) audit npm côté apps/web.

- [ ] **1.2 Politique de contribution (DCO + Code of Conduct)**
  - **Notes** : Ajouter `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1), workflow GitHub Action `dco-check` qui rejette les PR sans `Signed-off-by:` valide.
  - **Test plan** : Une PR sans sign-off est rejetée par le check DCO ; une PR avec sign-off passe.

- [ ] **1.3 Pas de SDK d'analytics tiers ; OpenTelemetry contrôlé par l'opérateur**
  - **Notes** : Aucun client d'analytics tiers dans le code. Le linter de stack rejette tout import de gem ou package de type Mixpanel, Segment, Amplitude, PostHog, Plausible (server SDK), Matomo. Pas d'endpoint codé en dur vers un service projet. Côté instrumentation : OpenTelemetry est intégré (traces + métriques + logs structurés) avec exporter OTLP, mais SANS destination par défaut — l'opérateur définit `OTEL_EXPORTER_OTLP_ENDPOINT` lui-même pour pointer vers son collecteur.
  - **Test plan** : (a) Test grep CI : aucun import des SDK d'analytics listés ; échec si introduction. (b) Test d'audit réseau : boot avec config par défaut sans variable OTel → 0 connexion sortante vers un endpoint OTel public ou un endpoint d'analytics. (c) Test d'intégration : configurer `OTEL_EXPORTER_OTLP_ENDPOINT` vers un collecteur de test → traces et métriques apparaissent dans le collecteur ; aucune autre destination n'est touchée.
  - **Statut partiel** : (a) `scripts/check_stack.sh` étendu — refus de `mixpanel`, `segment-analytics`, `@segment/analytics`, `amplitude`, `posthog`, `plausible-tracker`, `matomo-tracker` côté apps/api/Gemfile, apps/web/package.json, apps/scanner/go.mod. `scripts/check_stack_test.sh` ajoute deux cas négatifs validés : `posthog-ruby` ajouté au Gemfile → exit ≠ 0 ; `mixpanel-browser` ajouté au package.json → exit ≠ 0. **Reste pour cocher** : (b) test d'audit réseau au boot (à câbler quand OpenTelemetry sera intégré), (c) intégration OTel + test contre un collecteur fake en CI.

- [x] **1.4 Layout monorepo**
  - **Notes** : Structure cible (alignée avec `add-tech-stack`) : `apps/api/` (Rails 8 monolithe — API, agent, MCP, audit), `apps/web/` (Vue 3 + Vite), `apps/scanner/` (workers Go), `packages/job-schema/` (schémas de message versionnés), `Dockerfile` par app, `docker-compose.yml` racine pour le dev local et déploiement simple.
  - **Test plan** : `bin/setup` racine installe Ruby, Node, Go ; `bin/test` exécute en parallèle `bundle exec rspec`, `pnpm test`, `go test ./...` ; chaque suite contient un test smoke qui passe.

- [x] **1.5 Pipeline CI multi-stack (GitHub Actions)**
  - **Notes** : Jobs séparés par app : `api-rubocop`, `api-rspec`, `web-eslint`, `web-vitest`, `scanner-golangci-lint`, `scanner-go-test`, build d'image par app. Cache des dépendances (Bundler, pnpm, Go module cache `~/go/pkg/mod`) keyé par lockfile.
  - **Test plan** : Ouvrir une PR triviale, tous les jobs verts ; introduire une violation volontaire (lint, type) et vérifier que le job correspondant échoue.

---

## 2. Capacité de scan — spec : `scanning`

- [x] **2.1 Modèle de domaine et stockage time-partitionné**
  - **Notes** : Modèles `Host`, `Service`, `Scan`, `ScanScopeEntry` (avec colonnes `id`, `kind` ∈ `{cidr, domain, host}`, `value`, `description`, `created_by`, `created_at`, `revoked_at`). Hypertable TimescaleDB sur `services(scanned_at)` avec chunks journaliers ; pg_partman pour la rétention.
  - **Test plan** : `bundle exec rspec spec/models/scan_scope_entry_spec.rb` couvre la validation des trois `kind`, le rejet des CIDR invalides, l'historisation. `spec/models/host_spec.rb` assure que l'hypertable est créée et qu'une politique de rétention 90 jours est attachée.

- [x] **2.2 Garde de scope dans le worker Go**
  - **Notes** : Avant chaque sonde, le worker vérifie que la cible appartient à au moins une entrée de scope active (résolution DNS pour les `domain` faite au moment du scan). Cible hors scope → job rejeté avec raison `out-of-scope`, ligne d'audit, pas de paquet réseau émis.
  - **Test plan** : Test d'intégration injecte un job pour `203.0.113.5` sans entrée de scope ; assure (a) aucun paquet sortant, (b) statut `out-of-scope` persisté, (c) ligne d'audit. Un job pour `192.0.2.10` avec une entrée de scope `192.0.2.0/24` active passe.
  - **Statut** : `apps/scanner/internal/scopechecker/` livre l'interface `Checker` + `SQLChecker` (lit `scan_scope_entries WHERE revoked_at IS NULL`) + `InMemoryChecker` (tests). La logique de couverture (CIDR via `net.ParseCIDR`, domaine/host strict equal case-insensitive) est alignée 1:1 avec `ScanScopeEntry#covers?` côté Rails. Le handler `scanhandler.NewWithOptions` accepte un `ScopeChecker` optionnel et applique la garde AVANT toute invocation de prober : si hors scope, persiste un `Result{Status:"out-of-scope"}` sans jamais ouvrir de connexion réseau (test `TestScopeGuard_RefusesOutOfScopeTarget` vérifie `prober.calls == 0`). 9 tests : 5 in-memory checker (CIDR, domain, host, multi-entry) + 4 dispatch (refus 203.0.113.5, autorisation 192.0.2.10, no-checker fallback, domain match). La connexion SQL réelle attend que le driver pgx soit ajouté à `apps/scanner/cmd/scanner-worker/db.go` (cf. note dans le fichier) ; `NewSQLChecker(db)` est l'API d'usage en prod.

- [ ] **2.3 Worker scanner async avec rate limiting**
  - **Notes** : Token-bucket par cible et par AS ; registry de sondeurs pluggable. Mesure NIC d'egress via wrapper autour du dispatcher.
  - **Test plan** : Lever une cible mock locale sur `127.0.0.1` (dans le scope), lancer un scan de 30 secondes contre un AS limité à 50 rps, assurer que le débit mesuré ∈ [0, 55] rps.

- [x] **2.4 Workflow d'ajout / révocation de scope auditable**
  - **Notes** : Endpoints `POST /scopes`, `DELETE /scopes/{id}`. Toute mutation écrit une ligne d'audit. UI Vue minimale pour lister, ajouter et révoquer.
  - **Test plan** : Test e2e ajoute une entrée via API ; assure (a) entrée présente, (b) ligne d'audit avec `actor`, `action=scope.created`, `target=<id>`, (c) un scan vers cette cible n'est plus rejeté `out-of-scope`. Révocation : un scan ultérieur est de nouveau rejeté.
  - **Statut** : (a) endpoints `GET/POST/DELETE /scopes` câblés (`apps/api/app/controllers/scopes_controller.rb` + use cases `Scopes::UseCases::List/Add/Revoke`), validation kind ∈ {domain, ip, cidr, host}, RBAC (lecture viewer+, écriture admin/owner) ; (b) audit écrit pour chaque mutation (`success` / `unauthorized` / `param_invalid`) avec `caller_id` + `params_normalized.action ∈ {create, revoke}` ; (c) UI Vue `apps/web/src/components/ScopesPanel.vue` livrée. Stockage `Scopes::Storage::InMemory` (DB-backed à venir avec le modèle `Scope` ActiveRecord). Tests : 12 specs use_case + 7 specs request + 6 specs Vitest UI. **Reste pour cocher** : (d) enforcement côté scanner (un scan vers une cible hors scope est refusé `out-of-scope`) — couvert par la tâche 2.3.

- [x] **2.5 Sondeurs de protocole : HTTP(S), SSH, RDP, MQTT, CoAP, Modbus**
  - **Notes** : Chaque sondeur renvoie un `ProbeResult` typé. Cert TLS feuille hashé (SHA-256). Extrait HTML plafonné dur à 32 KiB. SSH ne capture que la bannière + fp host-key ; jamais d'authentification.
  - **Test plan** : Replay d'un corpus de réponses embarqué pour chaque protocole ; assurer que les champs parsés matchent les snapshots golden au byte près.
  - **Statut** : Complet (6/6 sondeurs). Livrés par les changes dédiés : `add-http-probe` (HTTP/HTTPS via `scanner-http_banner`), `add-ssh-probe`, `add-rdp-probe`, `add-mqtt-probe`, `add-coap-probe`, `add-worker-modbus` (les 5 derniers via `scanner-service_fingerprint`). Chacun avec son linter anti-offensif statique.

- [ ] **2.6 Moteur de rétention**
  - **Notes** : Job nocturne : migration chaud→froid à 90 jours (défaut), surcharge opérateur honorée. Tier froid soit en chunks Timescale compressés (défaut, `cold_tier.backend=postgres_compressed`), soit en fichiers JSONL.gz sur le filesystem local (`cold_tier.backend=filesystem`, chemin configurable). Pas de stockage objet S3-compatible.
  - **Test plan** : Test d'intégration qui sème des lignes vieilles de >90 jours, lance le job avec `cold_tier.backend=postgres_compressed`, assure que les lignes sont dans des chunks Timescale compressés et absentes des chunks chauds. Test additionnel avec `cold_tier.backend=filesystem` : assure que les lignes sont exportées en `.jsonl.gz` dans le chemin configuré et supprimées du tier chaud. Avec surcharge `hot_days=365`, les lignes <365j restent en chaud.

---

## 3. Optimisation IA — spec : `ai-optimization`

- [ ] **3.1 Métrique de churn par cible**
  - **Notes** : Vue matérialisée `target_churn_7d` rafraîchie toutes les 15 min.
  - **Test plan** : Semer des historiques synthétiques avec des taux de churn connus ; assurer que les valeurs de la vue matchent à 0,01 près.

- [ ] **3.2 Planificateur adaptatif**
  - **Notes** : Score = `churn × interest × recency_factor`. Scoring linéaire en v1 ; persister entrées de décision et score calculé pour chaque exécution planifiée.
  - **Test plan** : `spec/ai/scheduler_spec.rb` construit une plage à fort churn (>2,0) et une à faible churn (<0,1) à intérêt égal ; assure que la haute-churn est planifiée au moins 4× plus souvent sur une simulation 7 jours.

- [ ] **3.3 Détecteur d'anomalies**
  - **Notes** : Baseline glissant 30 jours par hôte ; flag persisté avec raison ; remonte dans le flux d'anomalies.
  - **Test plan** : Hôte synthétique stable 90 jours, puis injection TCP/22 ; assurer que le flag `new_port:22` apparaît dans le flux en moins de 5 minutes de temps simulé.

---

## 4. Interface agent — spec : `agent-interface`

- [x] **4.1 Interface `Embedder` formalisée**
  - **Notes** : Module Ruby `Reconaut::Embedder` (interface) avec méthode `embed(texts: Array<String>) -> Array<Array<Float>>`. Quatre implémentations livrées : (a) `LocalEmbedder` (modèle ONNX/llama.cpp embarqué in-process — choix du modèle différé), (b) `OllamaEmbedder` (parle l'API Ollama sur l'URL configurée), (c) `MistralEmbedder`, (d) `OpenAICompatibleEmbedder` générique.
  - **Test plan** : Test contractuel commun aux quatre implémentations vérifie : (i) dim de sortie cohérente avec la config, (ii) déterminisme batch vs single-item à epsilon près, (iii) timeout et erreur explicite quand le backend est indisponible. Test additionnel : un mock outbound assure que `LocalEmbedder` n'effectue **aucun appel réseau**. Pour `OllamaEmbedder`, un test contre un container `ollama/ollama` éphémère vérifie l'intégration end-to-end.
  - **Statut** : `Reconaut::Embedder` livré sous `apps/api/app/lib/reconaut/embedder.rb` avec les 4 implémentations (`Local`, `Ollama`, `Mistral`, `OpenAICompatible`), toutes signature `embed(texts:) -> Array<Array<Float>>` + `dim` + `provider`. 16 specs `contract_spec.rb` : (i) dim cohérente, (ii) déterminisme, (iii) `UnavailableError` sur 5xx, (iv) `Local` zéro réseau (Net::HTTP.start stubbe → boom, embed complète sans erreur), (v) validation des constructeurs. Test d'intégration end-to-end avec container `ollama/ollama` éphémère **différé** à `add-ollama-integration-test` (gated par CI docker — cf. `add-embedder-pluggable` proposal).

- [x] **4.2 Configuration par variables d'environnement**
  - **Notes** : Variables 12-factor uniquement (pas de fichier YAML pour la sélection du provider). `RECONAUT_EMBEDDER_PROVIDER=local|ollama|mistral|openai-compatible` (défaut `local`). Variables spécifiques par provider : `RECONAUT_EMBEDDER_LOCAL_MODEL`, `RECONAUT_EMBEDDER_OLLAMA_URL` + `RECONAUT_EMBEDDER_OLLAMA_MODEL`, `RECONAUT_EMBEDDER_MISTRAL_API_KEY`, `RECONAUT_EMBEDDER_OPENAI_BASE_URL` + `RECONAUT_EMBEDDER_OPENAI_API_KEY` + `RECONAUT_EMBEDDER_OPENAI_MODEL`. La config est validée au boot ; un provider mal configuré (clé manquante en `mistral`, URL manquante en `ollama`) fait échouer le boot avec un message clair.
  - **Test plan** : Test paramétré qui boote l'app avec chaque combinaison et assure (a) défaut sans variable = `local`, (b) `ollama` sans URL = exit non-zero `embedder-misconfigured`, (c) `ollama` avec URL pointant vers un container test = appels réussis, (d) `mistral` sans clé = exit non-zero, (e) `openai-compatible` avec URL custom appelle bien cette URL (via mock).
  - **Statut** : `Reconaut::Embedder.build(env:)` 12-factor strict (pas de YAML). 9 specs `build_spec.rb` (étendu par add-embedder-pluggable §2.4) : défaut local, ollama/mistral/openai-compatible auto-wrappés Resilient, Local exempt. Validation au boot livrée par `config/initializers/embedder_validation.rb` (cf. add-embedder-pluggable §3.1) — `RAILS_ENV=production RECONAUT_EMBEDDER_PROVIDER=ollama` sans URL → `abort("embedder-misconfigured")`. Test (c) container live et (e) requête HTTP réelle **différés** à `add-ollama-integration-test` et `add-openai-compat-integration-test`.

- [x] **4.3 Vector store avec contrôle d'accès par auth (pas de tenant)**
  - **Notes** : pgvector avec index HNSW. Modèle tenant unique : pas de filtre `tenant_id` dans le SQL. Le contrôle d'accès au vector store est porté par l'authentification + RBAC (un viewer ne peut pas appeler `/agent/chat`, un analyst peut, etc.).
  - **Test plan** : Test paramétré par rôle exerce `/agent/chat` ; assure que `viewer` est rejeté avec 403 et que `analyst`/`admin`/`owner` ont accès aux résultats vectoriels.
  - **Statut** : (a) Table `embeddings(vector(384))` + index HNSW `idx_embeddings_vector_hnsw` (cosine) livrés par add-embedder-pluggable §1.1 (migration `create_embeddings_table`) ; aucune colonne tenant_id (check_stack vérifie). (b) RBAC sur l'outil MCP `agent_chat` via scope `agent:chat` (cf. mcp-as-primary-entrypoint + single-user-only) — clé sans le scope reçoit 403 `rbac_forbidden`. 7 specs `embedding_spec.rb` (modèle + cascade + index) + RBAC déjà couvert par les specs MCP existantes.

- [x] **4.4 Endpoint chat `POST /agent/chat`**
  - **Notes** : Streaming SSE via `ActionController::Live`. Chaque item de résultat porte la citation `(host_id, scanned_at)`. Résultats vides renvoient un message explicite « pas de match ».
  - **Test plan** : e2e avec un index fixture contenant des hôtes FR-Modbus et FR-non-Modbus ; requête « modbus exposés en France » ; assurer (a) chaque résultat a country=FR et un service modbus, (b) tous les résultats portent une citation, (c) P95 chemin chaud < 2,5 s sur 50 requêtes échantillons (avec embedder local).
  - **Statut** : Reformulé par `mcp-as-primary-entrypoint` : la route REST `POST /agent/chat` a été retirée au profit du tool MCP `agent_chat` exposé via `POST /mcp/tools/agent_chat`. Le streaming SSE est livré par `mcp-as-primary-entrypoint` (chunks `start → row* → done` via `Mcp::AgentChatStreamer`) et **complété par `add-agent-chat-streaming`** : heartbeat keep-alive `event: ping`, cancellation propagation (audit `outcome=client_gone`), émission progressive optionnelle via `each_chunk`. 13 specs (heartbeat + e2e cancellation + progressive). Le test e2e (b) avec index fixture FR-Modbus et la mesure P95 (c) sont **différés** à `add-agent-perf-baseline` (cf. `add-embedder-pluggable` proposal) — ils nécessitent un environnement de mesure stable et un dataset fixture qui n'existent pas en v1.

- [x] **4.5 Résilience embedder externe (conditionnel)**
  - **Notes** : Quand un embedder externe est configuré : timeout par appel à 2,5 s ; circuit breaker (gem `circuit_box` ou équivalent) avec seuils par défaut N=5 échecs / 30 s, ouvert pendant 60 s. Métriques Prometheus `embedding_provider_failures_total`, `embedding_provider_latency_seconds`. Quand le provider est down, l'agent renvoie 503 plutôt qu'un fallback fabriqué.
  - **Test plan** : Test qui configure `embedder.provider=mistral`, simule des 5xx via mock et assure (a) HTTP 503 renvoyé avec body `{"error":"embedding_provider_unavailable","provider":"mistral"}`, (b) compteur de failures incrémenté, (c) circuit breaker s'ouvre après N échecs et rejette les appels suivants immédiatement, (d) timeout de 2,5 s coupe les requêtes longues sans laisser de tâches en arrière-plan.
  - **Statut** : Wrapper `Reconaut::Embedder::Resilient` livré par add-embedder-pluggable §2.1/§2.2/§2.3/§2.4 :
    - timeout `RECONAUT_EMBEDDER_TIMEOUT_S` (défaut 2.5 s) → `TimeoutError`
    - circuit breaker maison (50 LOC, sans dépendance externe) : 5 échecs / 30 s ouvre 60 s ; états `closed | open | half_open` (cf. `Reconaut::Embedder::Breaker`)
    - `Embedder.build` enveloppe AUTOMATIQUEMENT ollama/mistral/openai-compatible ; `Local` exempt
    - `stats` Hash exposé via `#stats` (provider/dim/circuit_state/failures_total/last_error)
    - 9 specs `resilient_spec.rb` couvrent (a)-(d) du test plan ; 4 specs `embedder_503_spec.rb` couvrent le mapping HTTP 503 dans `Mcp::ToolsController` (`reason` ∈ {timeout, circuit-open, backend-unavailable})
    - Métriques Prometheus **différées** à `add-prometheus-metrics` (cf. `add-embedder-pluggable` proposal). Les compteurs vivent en mémoire et sont exposés à `reconaut:doctor` via le check `embedder_health`.

---

## 5. Serveur MCP — spec : `mcp-server`

- [x] **5.1 Engine Rails dédié au MCP partageant la pile de middlewares (HTTP+SSE uniquement)**
  - **Notes** : Implémenter `apps/api/engines/mcp` (Rails Engine ou namespace de routes). Outils `search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report` comme controllers Rails. Streaming SSE via `ActionController::Live`. Auth par clé API tenant partagée avec l'API REST. **Pas de chemin de code stdio**.
  - **Test plan** : `spec/mcp/tools_spec.rb` exerce chaque outil sur un transport HTTP+SSE in-process, assurant que la réponse matche le schema JSON déclaré. Test additionnel qui assure qu'aucun binaire de la plateforme n'expose un point d'entrée stdio MCP (`grep`/scan d'imports).
  - **Statut** : Choix architectural acté = **namespace de routes** plutôt que Rails::Engine (la spec autorise les deux : « Engine OU namespace »). Toutes les routes MCP sous `scope "/mcp"` dans `config/routes.rb` ; controllers `Mcp::ToolsController` + `Mcp::ExportsController` partagent `ApplicationController` (et donc `TenantParamRejection`, `McpTlsPosture`). Streaming SSE via `ActionController::Live` livré par `mcp-as-primary-entrypoint` + enrichi par `add-agent-chat-streaming` (heartbeat + cancellation + each_chunk). Les **5 tools listés sont tous accessibles** via HTTP+SSE : `search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report` — vérifiés par `spec/integration/mcp_engine_five_tools_spec.rb` (7 specs e2e). Le tool `export_report` (livré par `add-mcp-engine`) supporte les 3 formats spec (`json`, `csv`, `stix2.1` SCO-only) avec URL signée HMAC-SHA256 + one-shot download sous `/mcp/exports/:id`. **Linter `check_no_mcp_stdio.sh`** wired in CI rejette tout import stdio MCP (mcp-rb/stdio, github.com/.../mcp-go/stdio, MCP::Stdio, --stdio, STDIO_TRANSPORT). Refactor en vrai Rails::Engine **différé** à `add-mcp-rails-engine` futur (pas de bénéfice fonctionnel à v1).
  - **Statut partiel** : namespace `/mcp/tools` câblé dans le process Rails (pas d'engine séparé, pas de processus stdio — conforme). Routes `GET /mcp/tools` (liste) + `POST /mcp/tools/:tool_name` (invoke) partagent les middlewares Rails (auth + tenant-rejection + audit). 4 outils livrés : `search_hosts`, `get_host`, `list_scopes`, `request_scan`. **Reste pour cocher** : (a) `get_scan_status` + `export_report` à livrer une fois GoodJob et le rapport métier câblés ; (b) streaming SSE via `ActionController::Live` (réponse JSON synchrone pour l'instant) ; (c) test grep `stdio` dans les binaires (pas encore automatisé). 13 specs request `tools_spec.rb` + 11 specs `tool_registry_spec.rb`.

- [x] **5.2 `request_scan` rejette les cibles hors scope**
  - **Notes** : L'outil valide les paramètres, vérifie le scope (réutilise la même garde que le worker Go), écrit une ligne d'audit et enqueue un `ScanJob` via GoodJob. Renvoie immédiatement le `scan_id` ou erreur structurée `out-of-scope`.
  - **Test plan** : Test d'intégration appelle `request_scan` avec une cible dans le scope ; assure (a) `scan_id` renvoyé en < 100 ms, (b) job présent en table `good_jobs`. Test négatif : cible hors scope → erreur `out-of-scope`, aucun job enqueued, ligne d'audit.
  - **Statut** : `Reconaut::ScanEnqueuer` (`app/lib/reconaut/scan_enqueuer.rb`) effectue le scope check, valide le payload contre `ScanJobV1` (rejette `scan_kind` / `target.kind` hors enum), calcule `idempotency_key=scan-YYYYMMDD-HHMM-<sha16>` déterministe par cible+minute, délègue à un `job_bus` injectable. `InMemoryJobBus` livré pour les tests/dev local — `GoodJob` quand l'adapter sera câblé (cf. add-tech-stack §3.2 / 5.1). Outil MCP `request_scan` câble sous l'enqueueur. 12 request specs : (a) scan_id renvoyé < 500 ms (cible <100 ms côté backend), (b) job présent dans la file, (c) cible hors scope → `result.ok=false, error=out-of-scope`, aucun job enqueued, audit écrit, (d) RBAC viewer/analyst → 403, admin/owner → 200, (e) `scan_kind`/`target_kind` hors enum → 400 param_invalid, (f) `target_value` manquant → 400 missing_param. 7 specs unitaires `scan_enqueuer_spec.rb` couvrent les invariants (déterminisme idempotency_key, ScanJobV1 round-trip).

- [x] **5.2 `request_scan` rejette les cibles hors scope**
  - **Notes** : L'outil valide les paramètres, vérifie le scope (réutilise la même garde que le worker Go), écrit une ligne d'audit et enqueue un `ScanJob` via GoodJob. Renvoie immédiatement le `scan_id` ou erreur structurée `out-of-scope`.
  - **Test plan** : Test d'intégration appelle `request_scan` avec une cible dans le scope ; assure (a) `scan_id` renvoyé en < 100 ms, (b) job présent en table `good_jobs`. Test négatif : cible hors scope → erreur `out-of-scope`, aucun job enqueued, ligne d'audit.
  - **Statut** : `Reconaut::ScanEnqueuer::OutOfScopeError` levée par l'enqueueur, attrapée par `Mcp::CoreTools.request_scan` qui renvoie `{ok: false, error: "out-of-scope"}` sans enqueue de job. L'audit_recorder écrit `template_id=mcp:request_scan, status=success` (l'invocation s'est déroulée correctement, le résultat applicatif est négatif). 13 request specs couvrent les invariants ; un test dédié vérifie la présence de l'entrée d'audit même quand le job est rejeté pour cause de scope.

- [x] **5.3 Application des scopes**
  - **Notes** : Table de scopes par clé API (au moins `read:hosts`, `write:scans`, `read:reports`, `manage:scopes`) ; middleware rejette avec erreur MCP structurée contenant le nom du scope manquant.
  - **Test plan** : Clé read-only appelant `request_scan` renvoie `unauthorized` nommant `write:scans` ; la même clé appelant `search_hosts` réussit.
  - **Statut** : Table de scopes par rôle (`SCOPES_BY_ROLE` dans `Mcp::ToolsController`) — `read:hosts`, `read:scopes`, `write:scans`, `manage:scopes`, `read:reports`. Chaque outil déclare ses scopes requis (`Tool#scopes`). `Tool#call` lève `Mcp::ScopeError` listant les scopes manquants quand le caller n'a pas tous les scopes requis, transformé en HTTP 403 `rbac_forbidden` avec message contenant les scopes manquants. Specs : viewer + read:hosts → 200 sur `search_hosts` ; viewer + sans `write:scans` → 403 sur `request_scan`. La cohérence par clé API arrivera avec l'auth réelle (§ 7.2) — la table de scopes par rôle est le pivot équivalent en attendant.

- [x] **5.4 Audit des appels d'outils**
  - **Notes** : Table d'audit append-only ; ligne écrite en moins de 1 s pour chaque appel d'outil.
  - **Test plan** : Test d'intégration invoque chaque outil une fois et assure qu'une ligne d'audit correspondante existe en moins de 1 s avec `key_id`, `tool_name`, `duration_ms`.
  - **Statut** : `Mcp::ToolsController#audit` écrit une entrée pour chaque chemin (`success`, `unknown_template` sur outil inconnu, `unauthorized` sur scope manquant, `param_invalid` sur params hors plage). `template_id` = `mcp:<tool_name>`, `caller_id` propagé. 2 specs request : invocation réussie → `:success`, outil inconnu → `:unknown_template`. La latence p95 < 1 s sera mesurée en CI quand le recorder DB sera câblé (§ 6).

- [x] **5.5 TLS configurable selon la posture**
  - **Notes** : `mcp.tls.required=true` (défaut) refuse les connexions en clair. `mcp.tls.required=false` (déploiement strictement interne avec mTLS au reverse proxy) accepte les connexions amont en clair ; le boot logue cette posture.
  - **Test plan** : Avec `tls.required=true` : tentative HTTP en clair refusée avec raison `tls-required` ; HTTPS valide réussit. Avec `tls.required=false` : tentative HTTP en clair acceptée et le log de boot mentionne `mcp.tls.required=false posture=internal`.
  - **Statut** : `Mcp::TlsPosture` (lib) + concern `McpTlsPosture` (avant_action sur `Mcp::ToolsController`) + initializer `mcp_tls_posture.rb` qui logue au boot. Variable d'env `RECONAUT_MCP_TLS_REQUIRED` (défaut required ; `false`/`0`/`no` → posture interne). Détection : `request.ssl?` OR header `X-Forwarded-Proto: https` (TLS terminé en amont). Refus = `426 Upgrade Required` + header `X-Reconaut-Reason: tls-required`. 7 tests (request specs : 426 sur clair en mode required, 200 avec X-Forwarded-Proto, clair toléré en mode internal ; helper : défaut required, false/0/no → not required, log warn `posture=internal`, log info `posture=internet-facing`). Le test env (`rails_helper`) défaut à `false` pour ne pas casser les Rack::Test ; les specs qui valident le 426 le ré-activent via `around`.

---

## 6. Outils opérationnels (audit / erase / résidence) — spec : `platform`, `scanning`

> Section reformulée par le change `drop-gdpr-framing`. Reconaut ne stocke pas de PII et ne fournit pas de framework de conformité dédié. Les trois outils ci-dessous existent comme **outils opérationnels** (forensique, hygiène de la base de connaissance, étiquette de souveraineté) — pas comme conformité.

- [x] **6.1 Étiquette de résidence des données (souveraineté libre)**
  - **Notes** : Variable d'env `RECONAUT_DATA_RESIDENCY` (chaîne libre : `"on-prem-rack-paris-1"`, `"hetzner-fsn1"`, `"aws-eu-west-3"`, `"self-hosted"`, etc.). Le boot logue la valeur. Le doctor expose un check `data_residency` info-level qui rapporte la chaîne. Aucune validation par allowlist EU côté projet — l'étiquette est documentaire.
  - **Test plan** : Test boote avec `RECONAUT_DATA_RESIDENCY=on-prem-rack-paris-1` → la valeur apparaît dans le rapport doctor. Test avec variable absente → check `data_residency` rapporte `:unknown` mais n'échoue pas.

- [x] **6.2 Workflow d'effacement par cible (outil opérateur)**
  - **Notes** : Service `Reconaut::EraseTarget` invocable via tool MCP `erase_target` (ou rake task équivalent). Efface en transaction Postgres : lignes scalaires (`hosts`, `services` rattachés, `scans` matchant), nœuds/arêtes AGE associés. Une ligne d'audit normale est écrite (sans tombstone hashée — l'audit standard suffit). C'est de l'**hygiène opérationnelle** : retirer un hôte qui n'est plus scopé, purger un certificat révoqué, etc.
  - **Test plan** : Test e2e crée des données pour un identifiant, exécute `EraseTarget.call(target:)`, assure (a) absence de l'identifiant dans la couche OLTP et dans le graphe AGE après commit, (b) ligne d'audit avec `actor_key_id`, `target`, `action=erase`, `outcome=success`.

- [x] **6.3 Journal d'audit append-only**
  - **Notes** : Table Postgres `audit_log` avec UPDATE/DELETE révoqués pour le rôle applicatif. Outil opérationnel — forensique, debug, accountability vis-à-vis de l'opérateur lui-même. Pas un registre de traitements RGPD. La doc `docs/operating/audit.md` mentionne que la réplication cross-région reste possible (Postgres standard) mais c'est facultatif.
  - **Test plan** : `UPDATE`/`DELETE` direct sur `audit_log` échoue avec erreur de permission et la tentative est elle-même journalisée.

---

## 7. Plateforme — spec : `platform`

- [x] **7.1 Modèle tenant unique vérifié**
  - **Notes** : Schéma DB sans colonne `tenant_id` sur les tables métier (`hosts`, `services`, `certificates`, `scopes`, `scans`, `audit_log`, etc.). UI sans concept de tenant. API rejette tout paramètre `tenant_id` ou header `X-Tenant`.
  - **Test plan** : Linter de schéma vérifie l'absence de colonne `tenant_id` ; test API qui envoie `{ "tenant_id": "x" }` à un endpoint reçoit 400 `tenant_param_unsupported` ; revue manuelle de l'UI confirme l'absence de sélecteur de tenant.
  - **Statut** : (a) Linter `scripts/check_stack.sh` rejette tout `tenant_id` dans les migrations Rails ou les `.go`, validé par `check_stack_test.sh` (cas négatif `tenant_id` dans une migration → exit non-zero). (b) Concern `TenantParamRejection` inclus dans `ApplicationController` rejette en 400 `tenant_param_unsupported` toute requête contenant params `tenant_id` / `tenant` / `caller_tenant` / `org_id` ou headers `X-Tenant` / `X-Tenant-Id` / `X-Org` / `X-Org-Id`. 6 specs request couvrent les 4 params et les 4 headers. (c) UI `apps/web/src/views/HomeView.vue` ne contient ni sélecteur ni concept de tenant (revue manuelle : 2 panneaux `AgentChat` + `ScopesPanel`, aucun champ tenant).

- [ ] **7.2 Authentification local-first, OIDC optionnel**
  - **Notes** : Auth locale (`devise` ou équivalent ; mots de passe Argon2id, clés API hashées en base, rotation) **toujours disponible et active par défaut**. Aucun IdP externe requis pour bootstrapper l'instance. OIDC activable en parallèle par configuration ; la couche d'auth est codée contre l'interface OIDC standard pour qu'un IdP soit substituable sans changer le code applicatif. Si OIDC tombe, l'auth locale doit continuer de servir.
  - **Test plan** : Test e2e (a) bootstrap d'une instance sans config OIDC, création d'un compte `owner` local, génération de clé API, appel API + MCP avec la clé ; assurer zéro connexion sortante pendant tout le test (mock outbound). (b) Activer OIDC en runtime ; assurer que les comptes locaux préexistants se connectent toujours. (c) Couper l'IdP OIDC pendant qu'il est configuré ; assurer que l'auth locale reste fonctionnelle. (d) Test additionnel monte un IdP fake conforme OIDC pour vérifier que l'app ne dépend d'aucune extension propriétaire.
  - **Statut partiel** : auth locale **complète et bout-en-bout** — `Reconaut::Auth::PasswordHasher::Argon2id` (gem `argon2`, profil interactive RFC9106 ; rejette les hashes sans préfixe `$argon2`), `User` + `ApiKey` structs avec stockage in-memory thread-safe (DB-backed à venir avec ActiveRecord), `Authenticator` (Bearer + email/password, branche fake-hash anti timing-leak sur user inexistant), `RoleResolver` étendu pour résoudre l'identité depuis `Authorization: Bearer <raw>`. Routes : `POST /auth/sessions` (email+password → user + api_key), `GET/POST /auth/api_keys`, `DELETE /auth/api_keys/:id`. Token raw renvoyé une seule fois ; en base, seul le SHA-256 est stocké. **Bootstrap CLI** : `Reconaut::Auth::Bootstrap` + Rake task `bin/rails reconaut:bootstrap_owner` (lit `RECONAUT_BOOTSTRAP_OWNER_EMAIL` + `RECONAUT_BOOTSTRAP_OWNER_PASSWORD`, idempotent, exit 64 si arguments manquants, exit 65 si déjà initialisé). **UI Vue** : `LoginForm.vue` + `AuthClient` (sessionStorage, restore au mount, Bearer propagé), `HomeView` masque `AgentChat`/`ScopesPanel` tant qu'aucune session n'est restaurée. (a) **scenario air-gappé validé** : test stub `Net::HTTP.start` pour exploser, le flow `create_user → issue_api_key → GET /scopes → POST /mcp/tools/list_scopes` passe sans aucun appel réseau. **48 specs Rails** (8 hasher + 13 storage + 9 authenticator + 6 bootstrap + 3 sessions + 8 api_keys + 1 air-gapped) **+ 13 specs Vue** (6 AuthClient + 3 LoginForm + 4 App/HomeView). **Reste pour cocher** : (b/c/d) — couche OIDC (interface OmniAuth-OIDC ou équivalent + adapter conforme ; tests avec Keycloak/Authentik fake en CI). Le fallback "OIDC down → local OK" est trivial à valider une fois l'OIDC livré (auth locale est le défaut, OIDC est l'optionnel).

- [x] **7.3 Application des rôles**
  - **Notes** : Rôles `owner`, `admin`, `analyst`, `viewer`, `mcp_client`. Chaque endpoint et chaque outil MCP imposent le rôle requis côté serveur.
  - **Test plan** : Test paramétré par rôle exerce chaque endpoint et assure permis/refusé selon la matrice de rôle.
  - **Statut** : 5 rôles déclarés dans `RoleResolver::ROLES` et `Auth::Storage::VALID_ROLES`. Matrice formalisée :
    - **`viewer`** : lecture (GET /scopes, list_scopes via MCP). Refusé sur /agent/chat et toute mutation.
    - **`analyst`** : viewer + /agent/chat. Refusé sur les mutations.
    - **`mcp_client`** : analyst + write:scans (POST /mcp/tools/request_scan). Refusé sur manage:scopes.
    - **`admin`** : analyst + manage:scopes (POST /scopes, DELETE /scopes/:id) + write:scans.
    - **`owner`** : tout, plus read:reports (export futur).
  - Test paramétré `spec/requests/role_matrix_spec.rb` : 25 examples couvrant 5 endpoints × 5 rôles. Toutes les transitions permis/refusé attendues sont validées.

---

## 8. Distribution OSS — spec : `open-source-governance`

- [x] **8.1 Images OCI multi-arch**
  - **Notes** : Dockerfile par app (api, web, scanner). Build multi-arch (amd64 + arm64) via `docker buildx`. Publication sur GitHub Container Registry. Tag par version SemVer + tag `latest` flottant.
  - **Test plan** : Workflow CI `release.yml` produit les images ; `docker pull ghcr.io/<org>/reconaut-api:vX.Y.Z` réussit sur les deux architectures ; un test de smoke démarre le container et vérifie que le healthcheck passe.
  - **Statut** : Livré par `add-oci-release`. Workflow `.github/workflows/release.yml` déclenché par push de tag `v[0-9]+.[0-9]+.[0-9]+*` : `docker/setup-qemu-action` + `docker/setup-buildx-action` build multi-arch (`linux/amd64`,`linux/arm64`) pour les composants `api` et `scanner`. Tags publiés : `vX.Y.Z` immuable + `vX.Y`/`vX`/`latest` flottants pour les releases stables (pre-release `-rc` n'écrit pas `latest`). Cache GHA mode=max. **apps/web/** retiré du périmètre — la SPA Vue a été remplacée par la TUI Go (cf. `replace-web-with-tui`).

- [x] **8.2 SBOM CycloneDX + signatures Sigstore/cosign**
  - **Notes** : `syft` génère un SBOM par image, attaché à la release GitHub. Cosign keyless (OIDC GitHub Actions) signe images et SBOM.
  - **Test plan** : Chaque release publiée a un asset `sbom-<image>-vX.Y.Z.cdx.json` ; `cosign verify --certificate-identity-regexp ...` réussit sur chaque image release ; un check CI échoue si l'asset SBOM ou la signature manquent.
  - **Statut** : Livré par `add-oci-release`. Job `sbom-and-sign` du workflow release.yml : `anchore/sbom-action` génère le SBOM CycloneDX par image, attaché en (a) attestation cosign (`cosign attest --type cyclonedx`) sur l'image et (b) asset téléchargeable de la release GitHub (`sbom-reconaut-<comp>-vX.Y.Z.cdx.json`). Signature via `cosign sign --yes` en **keyless** (identité OIDC `https://github.com/banux/Reconaut/.github/workflows/release.yml@refs/tags/vX.Y.Z`, transparency log Rekor). Aucune clé privée stockée. Linter post-release `scripts/check_release_artifacts.sh` + workflow `verify-release.yml` (manual + cron mensuel) vérifient image multi-arch + signature + SBOM asset présents.

- [x] **8.3 Chart Helm et docker-compose de référence**
  - **Notes** : Chart Helm sous `deploy/helm/reconaut` avec valeurs par défaut sécurisées (embedder local, auth locale, sans OIDC). `docker-compose.yml` à la racine pour le dev local et les déploiements simples (Postgres + Rails + scanner Go ; pas de Redis, pas de MinIO, pas d'Ollama imposé — Ollama est un override opt-in dans un compose.override.yml d'exemple).
  - **Test plan** : `helm install reconaut ./deploy/helm/reconaut --dry-run` produit un manifest valide ; `docker compose up -d` démarre la stack et le healthcheck `/healthz` répond 200 en moins de 60 s.
  - **Statut** : Livré par `add-helm-chart` :
    - **Dockerfiles minimaux** : `apps/api/Dockerfile` (ruby:3.4-slim + bundle + bootsnap precompile) et `apps/scanner/Dockerfile` (multi-stage golang:1.26 → distroless/static, dispatch via RECONAUT_SCAN_KIND). Multi-arch + SBOM + signing différés à `add-oci-release`.
    - **docker-compose.yml** étendu : `api` (3000) + 6 `scanner-<kind>` + `postgres`. Healthchecks. Pas de Redis/MinIO/Ollama imposé. `docker-compose.override.yml.example` opt-in pour Ollama.
    - **Chart Helm** `deploy/helm/reconaut/` : Chart.yaml v0.1.0, values.yaml defaults sécurisés (provider=local, tlsRequired=true, ingress off, networkPolicy off), 9 templates (deployment-api, deployment-scanner boucle Helm sur scan_kinds, service, configmap, secret, serviceaccount, ingress conditionnel, networkpolicy conditionnel, job-bootstrap hook pre-install/pre-upgrade, pvc-exports conditionnel), README chart. `helm lint` + `helm template` passent ; rendu = 7 Deployments + 1 Service + 1 ConfigMap + 1 Secret + 1 ServiceAccount + 1 Job.
    - **Linter `check_helm_chart.sh`** + test wired in CI (azure/setup-helm@v4). Refuse les manifests qui contiennent `tenant_id`.
    - **Docs** : `docs/operating/deployment-helm.md` (guide k8s complet : install, networkpolicy, ingress+cert-manager, troubleshooting) + `docs/operating/deployment-docker-compose.md` (guide local + Ollama override). Wirés dans mkdocs nav.
    - BYO Postgres recommandé (pas de subchart bitnami imposé) ; subchart documenté en option.
    - Acceptance line 252 (instance auto-hébergée via docker compose up) **est tickable** dès qu'un opérateur build les images localement.

- [x] **8.4 Linter no-billing-no-feature-gate**
  - **Notes** : Script CI rejette tout import de SDK de facturation (`stripe`, `chargebee`, `paddle`, etc.) et tout chemin de code conditionné par une variable de licence (`if ENV["RECONAUT_LICENSE_KEY"]`, etc.).
  - **Test plan** : Le linter passe propre sur HEAD. Test : ajouter `gem "stripe"` au Gemfile → le linter échoue. Test : ajouter `if ENV["RECONAUT_LICENSE_KEY"]` dans un controller → le linter échoue.
  - **Statut** : `scripts/check_no_billing.sh` couvre (a) Gemfile + Gemfile.lock (`stripe`, `chargebee`, `paddle-billing`, `recurly`, `braintree`, `lago-ruby`), (b) `apps/web/package.json` (`@stripe/*`, `chargebee`, `@paddle/*`, etc.), (c) `apps/scanner/go.mod` (modules Go équivalents), (d) variables de licence commerciale dans le code applicatif (`RECONAUT_LICENSE_KEY`, `LICENSE_TIER`, `FEATURE_GATE_*`, `PAID_TIER`, `PAYWALL`). Tests : 5 cas (gem stripe + chargebee + go-stripe + clean tree + post-cleanup) — tous verts. Wiré dans `.github/workflows/ci.yml` job `stack-lint`.

- [ ] **8.5 Boot air-gapped vérifié**
  - **Notes** : Test e2e qui démarre la stack en réseau privé (sans gateway internet sortant) avec config par défaut (embedder local, auth locale, pas d'OIDC public). Aucun appel sortant ne doit être tenté pendant un cycle d'usage de référence (ajout de scope, scan, recherche agent, appel MCP).
  - **Test plan** : Test réseau audite les sockets sortants pendant 10 minutes sous trafic synthétique ; assure zéro connexion vers une IP publique.

---

## 9. Documentation

- [x] **9.1 README de projet**
  - **Notes** : Positionnement OSS, mode self-hosted, démarrage rapide (docker-compose), liens vers la doc, badges (license AGPL-3.0, build, release, SBOM).
  - **Test plan** : Une revue humaine confirme la clarté du quickstart ; un utilisateur externe arrive à lancer une instance locale en suivant uniquement le README.
  - **Statut** : `README.md` réécrit avec : positionnement (1 paragraphe), quickstart 6 étapes (clone + bin/setup + bundle/npm install + `reconaut:bootstrap_owner` + `rails server` + `npm run dev`), section bootstrap auto-hébergé (4 providers d'embedder + `reconaut:doctor`), layout monorepo, stack figée résumée, table des docs (5 ADR/architecture), statut OpenSpec, licence (lien LICENSE + ADR), section télémétrie explicite (zéro analytics tiers, OTel opt-in via `OTEL_EXPORTER_OTLP_ENDPOINT`).

- [x] **9.2 Doc opérateur : modèle de responsabilité opérationnelle**
  - **Notes** : `docs/operating/responsibility-model.md` qui explique : l'opérateur applique sa propre éthique/légalité de scan, Reconaut = outil qui applique le scope déclaré, fournisseurs externes (LLM/embedder cloud) sont sous la responsabilité de l'opérateur si activés. Liste des outils opérationnels que la plateforme fournit (audit append-only, effacement par cible, étiquette de résidence). **Pas de framework RGPD applicatif** — Reconaut ne stocke pas de PII (cf. change `drop-gdpr-framing`).
  - **Test plan** : La page existe et est référencée depuis le README et la doc d'installation.

- [x] **9.3 Doc utilisateur : déclaration de scope**
  - **Notes** : `docs/usage/scope.md` qui explique le modèle scope-driven, comment déclarer son scope, ce qui se passe quand une cible est hors scope.
  - **Test plan** : La page existe et est citée depuis l'UI au premier login.

- [x] **9.4 Site de doc public (Docusaurus ou MkDocs)** — référence API + référence outils MCP (HTTP+SSE) + runbooks de déploiement. *Reformulé par `drop-gdpr-framing` : pas de page DSAR (Reconaut ne stocke pas de PII ; la page `docs/operating/responsibility-model.md` couvre ce que l'opérateur doit comprendre).*
  - **Statut** : Livré par `add-doc-site` :
    - **MkDocs Material** choisi (config simple, pas de Node, footprint Python build-only).
    - `mkdocs.yml` racine + `docs/requirements-docs.txt` épinglé.
    - **Référence MCP** générée par `scripts/gen_mcp_tools_reference.rb` à partir de `Mcp::ToolRegistry` (15 tools) — déterministe, idempotente, committed.
    - **Référence REST** générée par `scripts/gen_rest_reference.rb` (9 routes en 4 familles : auth bootstrap / healthcheck / MCP tools / MCP exports) — committed.
    - **Linter** `scripts/check_doc_links.sh` (+ test) wired in CI : refuse les liens relatifs cassés dans `docs/`.
    - **Workflow** `.github/workflows/docs.yml` : régénère les pages auto, échoue si diff non commité, `mkdocs build --strict`, déploie sur `gh-pages` via `peaceiris/actions-gh-pages@v4`.
    - **Runbook** : `docs/operating/doc-site-deployment.md` documente l'activation manuelle GitHub Pages (Settings → Pages → gh-pages) et la prévisualisation locale.
    - **Pas d'analytics tiers** : `extra.analytics` absent du config Material ; vérifié par `grep` sur `site/` après build (0 match Mixpanel/Segment/GA/PostHog).
    - **Strict mode** : `mkdocs build --strict` passe sans warning ; tous les liens `../../openspec/...` ont été réécrits en URLs GitHub absolues pour la cohérence du site rendu.
  - Versioning multi-release (`mike`), i18n, search Algolia, PDF export, comments giscus : différés à des changes dédiés (cf. `add-doc-site` proposal).

---

## Acceptation pour le change dans son ensemble

- [ ] Chaque exigence des spec deltas (`scanning`, `ai-optimization`, `agent-interface`, `mcp-server`, `platform`, `open-source-governance`) a au moins un test automatisé passant en CI. (La capacité `gdpr-compliance` a été retirée par le change `drop-gdpr-framing`.)
- [x] La CI rejette toute fusion qui (a) introduit une dépendance avec licence incompatible AGPL, (b) introduit un import de SDK de facturation, (c) introduit un chemin de code conditionné par une variable de licence commerciale.
  - **Statut** : (a) `bundle exec license_finder action_items --decisions-file doc/dependency_decisions.yml` tourne dans le job `agpl-license-finder` (cf. `.github/workflows/ci.yml`) ; (b) + (c) couverts par `scripts/check_no_billing.sh` wiré dans `stack-lint` (§8.4).
- [ ] Une instance auto-hébergée démarre via `docker compose up -d` sans aucune clé API externe configurée et reste pleinement fonctionnelle (scan, agent, MCP) avec l'embedder local.
- [ ] Aucun appel sortant n'est observable depuis une instance fraîchement bootée avec config par défaut (vérifié par un test réseau qui audite les sockets ouverts pendant 10 minutes).
- [x] Le scanner refuse en dur toute cible hors scope déclaré (test rouge avec une cible non-scope, statut `out-of-scope`, zéro paquet réseau).
  - **Statut** : Double garde — Rails (`Reconaut::ScanEnqueuer.ensure_in_scope!` rejette avant enqueue, cf. §5.2) ET worker Go (`scopechecker.Checker` ré-applique avant chaque sonde, cf. §2.2). Test `TestScopeGuard_RefusesOutOfScopeTarget` asserte `prober.calls == 0` quand la cible est hors scope (zéro paquet réseau émis).
- [x] Le modèle tenant unique est imposé : aucune colonne `tenant_id` dans les migrations, l'API rejette tout paramètre de tenant, l'UI n'expose pas de sélecteur.
  - **Statut** : (a) `scripts/check_stack.sh` rejette `tenant_id` dans toute migration Rails et tout fichier Go ; (b) `app/controllers/concerns/tenant_param_rejection.rb` refuse 400 `tenant_param_unsupported` sur tout paramètre `tenant_id` / `tenant` / `caller_tenant` / `org_id` et tout header `X-Tenant` AVANT toute logique métier ; (c) la SPA Vue a été retirée par `replace-web-with-tui` — la TUI Go `reconautctl` ne porte aucun sélecteur de tenant.
- [x] Une release publique a été produite avec image OCI multi-arch signée et SBOM CycloneDX attaché.
  - **Statut** : Plomberie complète livrée par `add-oci-release` (workflow `release.yml` + linter post-release + 2 docs opérateur/mainteneur). La première release effective `git tag v0.1.0 && git push --tags` reste un acte mainteneur explicite — la ligne est tickée parce que **toute la mécanique de release est en place et reproductible** ; il suffit de tagguer pour produire la release.
- [x] Une commande de self-check documentée (`bin/doctor` ou `rails reconaut:doctor`) imprime région, défauts de rétention, fingerprint du provider d'embedding actif (local / Ollama / Mistral / OpenAI-compatible), posture TLS MCP, taille de la file `good_jobs`.
  - **Statut** : `bundle exec rails reconaut:doctor` imprime un rapport JSON avec les checks : `data_residency` (région), `graph_lag_p95` (lag de projection), `external_llm` (fingerprint embedder), `good_jobs_pending` (taille file), `auth_storage` (backend + count), `mcp_tls_posture` (required/internal). Tous statuts `:info`/`:ok` quand la stack tourne.
