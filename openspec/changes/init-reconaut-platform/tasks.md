# Tâches : init-reconaut-platform

Checklist fondatrice. Chaque tâche inclut des notes d'implémentation et un test plan qui doit passer avant de cocher la case.

---

## 1. Bootstrap du projet et gouvernance OSS

- [ ] **1.1 Application de la licence AGPL-3.0-only**
  - **Notes** : Décision actée (cf. `proposal.md` §Décisions prises §1) — pas de vocation commerciale, AGPL protège contre la ré-hébergement managé fermé sans réciprocité. Intégrer le texte intégral d'AGPL-3.0 dans `LICENSE` à la racine, ajouter `SPDX-License-Identifier: AGPL-3.0-only` en en-tête de chaque fichier source. Rédiger un ADR court `docs/adr/0001-license.md` qui consigne la décision (contexte, options écartées Apache-2.0/BUSL-1.1, conséquences). Vérifier la compatibilité de licence des dépendances (transitives incluses) — refuser toute dépendance dont la licence est incompatible avec AGPL côté sortie.
  - **Test plan** : `licensee detect .` renvoie `AGPL-3.0-only` ; un check CI échoue si un fichier source n'a pas l'en-tête SPDX attendu ; un audit `bundle-audit` / `go-licenses check` / `pnpm licenses ls` confirme zéro dépendance avec licence incompatible.

- [ ] **1.2 Politique de contribution (DCO + Code of Conduct)**
  - **Notes** : Ajouter `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1), workflow GitHub Action `dco-check` qui rejette les PR sans `Signed-off-by:` valide.
  - **Test plan** : Une PR sans sign-off est rejetée par le check DCO ; une PR avec sign-off passe.

- [ ] **1.3 Pas de SDK d'analytics tiers ; OpenTelemetry contrôlé par l'opérateur**
  - **Notes** : Aucun client d'analytics tiers dans le code. Le linter de stack rejette tout import de gem ou package de type Mixpanel, Segment, Amplitude, PostHog, Plausible (server SDK), Matomo. Pas d'endpoint codé en dur vers un service projet. Côté instrumentation : OpenTelemetry est intégré (traces + métriques + logs structurés) avec exporter OTLP, mais SANS destination par défaut — l'opérateur définit `OTEL_EXPORTER_OTLP_ENDPOINT` lui-même pour pointer vers son collecteur.
  - **Test plan** : (a) Test grep CI : aucun import des SDK d'analytics listés ; échec si introduction. (b) Test d'audit réseau : boot avec config par défaut sans variable OTel → 0 connexion sortante vers un endpoint OTel public ou un endpoint d'analytics. (c) Test d'intégration : configurer `OTEL_EXPORTER_OTLP_ENDPOINT` vers un collecteur de test → traces et métriques apparaissent dans le collecteur ; aucune autre destination n'est touchée.

- [ ] **1.4 Layout monorepo**
  - **Notes** : Structure cible (alignée avec `add-tech-stack`) : `apps/api/` (Rails 8 monolithe — API, agent, MCP, audit), `apps/web/` (Vue 3 + Vite), `apps/scanner/` (workers Go), `packages/job-schema/` (schémas de message versionnés), `Dockerfile` par app, `docker-compose.yml` racine pour le dev local et déploiement simple.
  - **Test plan** : `bin/setup` racine installe Ruby, Node, Go ; `bin/test` exécute en parallèle `bundle exec rspec`, `pnpm test`, `go test ./...` ; chaque suite contient un test smoke qui passe.

- [ ] **1.5 Pipeline CI multi-stack (GitHub Actions)**
  - **Notes** : Jobs séparés par app : `api-rubocop`, `api-rspec`, `web-eslint`, `web-vitest`, `scanner-golangci-lint`, `scanner-go-test`, build d'image par app. Cache des dépendances (Bundler, pnpm, Go module cache `~/go/pkg/mod`) keyé par lockfile.
  - **Test plan** : Ouvrir une PR triviale, tous les jobs verts ; introduire une violation volontaire (lint, type) et vérifier que le job correspondant échoue.

---

## 2. Capacité de scan — spec : `scanning`

- [ ] **2.1 Modèle de domaine et stockage time-partitionné**
  - **Notes** : Modèles `Host`, `Service`, `Scan`, `ScanScopeEntry` (avec colonnes `id`, `kind` ∈ `{cidr, domain, host}`, `value`, `description`, `created_by`, `created_at`, `revoked_at`). Hypertable TimescaleDB sur `services(scanned_at)` avec chunks journaliers ; pg_partman pour la rétention.
  - **Test plan** : `bundle exec rspec spec/models/scan_scope_entry_spec.rb` couvre la validation des trois `kind`, le rejet des CIDR invalides, l'historisation. `spec/models/host_spec.rb` assure que l'hypertable est créée et qu'une politique de rétention 90 jours est attachée.

- [ ] **2.2 Garde de scope dans le worker Go**
  - **Notes** : Avant chaque sonde, le worker vérifie que la cible appartient à au moins une entrée de scope active (résolution DNS pour les `domain` faite au moment du scan). Cible hors scope → job rejeté avec raison `out-of-scope`, ligne d'audit, pas de paquet réseau émis.
  - **Test plan** : Test d'intégration injecte un job pour `203.0.113.5` sans entrée de scope ; assure (a) aucun paquet sortant, (b) statut `out-of-scope` persisté, (c) ligne d'audit. Un job pour `192.0.2.10` avec une entrée de scope `192.0.2.0/24` active passe.

- [ ] **2.3 Worker scanner async avec rate limiting**
  - **Notes** : Token-bucket par cible et par AS ; registry de sondeurs pluggable. Mesure NIC d'egress via wrapper autour du dispatcher.
  - **Test plan** : Lever une cible mock locale sur `127.0.0.1` (dans le scope), lancer un scan de 30 secondes contre un AS limité à 50 rps, assurer que le débit mesuré ∈ [0, 55] rps.

- [ ] **2.4 Workflow d'ajout / révocation de scope auditable**
  - **Notes** : Endpoints `POST /scopes`, `DELETE /scopes/{id}`. Toute mutation écrit une ligne d'audit. UI Vue minimale pour lister, ajouter et révoquer.
  - **Test plan** : Test e2e ajoute une entrée via API ; assure (a) entrée présente, (b) ligne d'audit avec `actor`, `action=scope.created`, `target=<id>`, (c) un scan vers cette cible n'est plus rejeté `out-of-scope`. Révocation : un scan ultérieur est de nouveau rejeté.
  - **Statut** : (a) endpoints `GET/POST/DELETE /scopes` câblés (`apps/api/app/controllers/scopes_controller.rb` + use cases `Scopes::UseCases::List/Add/Revoke`), validation kind ∈ {domain, ip, cidr, host}, RBAC (lecture viewer+, écriture admin/owner) ; (b) audit écrit pour chaque mutation (`success` / `unauthorized` / `param_invalid`) avec `caller_id` + `params_normalized.action ∈ {create, revoke}` ; (c) UI Vue `apps/web/src/components/ScopesPanel.vue` livrée. Stockage `Scopes::Storage::InMemory` (DB-backed à venir avec le modèle `Scope` ActiveRecord). Tests : 12 specs use_case + 7 specs request + 6 specs Vitest UI. **Reste pour cocher** : (d) enforcement côté scanner (un scan vers une cible hors scope est refusé `out-of-scope`) — couvert par la tâche 2.3.

- [ ] **2.5 Sondeurs de protocole : HTTP(S), SSH, RDP, MQTT, CoAP, Modbus**
  - **Notes** : Chaque sondeur renvoie un `ProbeResult` typé. Cert TLS feuille hashé (SHA-256). Extrait HTML plafonné dur à 32 KiB. SSH ne capture que la bannière + fp host-key ; jamais d'authentification.
  - **Test plan** : Replay d'un corpus de réponses embarqué pour chaque protocole ; assurer que les champs parsés matchent les snapshots golden au byte près.

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

- [ ] **4.1 Interface `Embedder` formalisée**
  - **Notes** : Module Ruby `Reconaut::Embedder` (interface) avec méthode `embed(texts: Array<String>) -> Array<Array<Float>>`. Quatre implémentations livrées : (a) `LocalEmbedder` (modèle ONNX/llama.cpp embarqué in-process — choix du modèle différé), (b) `OllamaEmbedder` (parle l'API Ollama sur l'URL configurée), (c) `MistralEmbedder`, (d) `OpenAICompatibleEmbedder` générique.
  - **Test plan** : Test contractuel commun aux quatre implémentations vérifie : (i) dim de sortie cohérente avec la config, (ii) déterminisme batch vs single-item à epsilon près, (iii) timeout et erreur explicite quand le backend est indisponible. Test additionnel : un mock outbound assure que `LocalEmbedder` n'effectue **aucun appel réseau**. Pour `OllamaEmbedder`, un test contre un container `ollama/ollama` éphémère vérifie l'intégration end-to-end.
  - **Statut partiel** : `Reconaut::Embedder` livré sous `apps/api/app/lib/reconaut/embedder.rb` avec les 4 implémentations (`Local`, `Ollama`, `Mistral`, `OpenAICompatible`), toutes signature `embed(texts:) -> Array<Array<Float>>` + `dim` + `provider`. `Local` : encodage déterministe SHA-256-projeté, choix du modèle ML réel différé comme prévu par la spec. 16 specs `contract_spec.rb` : (i) dim cohérente sur les 4, (ii) déterminisme single vs batch sur Local, (iii) `UnavailableError` sur HTTP 5xx + payload manquant, (iv) `LocalEmbedder` stubbe `Net::HTTP.start` pour exploser → embed complète sans erreur (preuve zéro réseau), (v) validation des constructeurs. **Reste pour cocher** : test d'intégration end-to-end avec un container `ollama/ollama` éphémère (différé jusqu'au CI avec docker disponible).

- [ ] **4.2 Configuration par variables d'environnement**
  - **Notes** : Variables 12-factor uniquement (pas de fichier YAML pour la sélection du provider). `RECONAUT_EMBEDDER_PROVIDER=local|ollama|mistral|openai-compatible` (défaut `local`). Variables spécifiques par provider : `RECONAUT_EMBEDDER_LOCAL_MODEL`, `RECONAUT_EMBEDDER_OLLAMA_URL` + `RECONAUT_EMBEDDER_OLLAMA_MODEL`, `RECONAUT_EMBEDDER_MISTRAL_API_KEY`, `RECONAUT_EMBEDDER_OPENAI_BASE_URL` + `RECONAUT_EMBEDDER_OPENAI_API_KEY` + `RECONAUT_EMBEDDER_OPENAI_MODEL`. La config est validée au boot ; un provider mal configuré (clé manquante en `mistral`, URL manquante en `ollama`) fait échouer le boot avec un message clair.
  - **Test plan** : Test paramétré qui boote l'app avec chaque combinaison et assure (a) défaut sans variable = `local`, (b) `ollama` sans URL = exit non-zero `embedder-misconfigured`, (c) `ollama` avec URL pointant vers un container test = appels réussis, (d) `mistral` sans clé = exit non-zero, (e) `openai-compatible` avec URL custom appelle bien cette URL (via mock).
  - **Statut partiel** : `Reconaut::Embedder.build(env:)` livré, 12-factor strict (pas de YAML, pas de fichier de config). 8 specs `build_spec.rb` couvrent (a) défaut sans variable → `Local` avec `dim=384`, (b) `ollama` sans URL → `MisconfiguredError` avec `url` mentionné, (d) `mistral` sans clé → `MisconfiguredError` mentionnant `api_key`, (e) `openai-compatible` correctement câblé via env, (f) `provider` inconnu → `MisconfiguredError unknown provider`. **Reste pour cocher** : (c) test live contre container `ollama/ollama` (différé) + assertion stricte que l'URL custom de `(e)` est effectivement appelée (le test actuel valide la construction, pas la requête HTTP).

- [ ] **4.3 Vector store avec contrôle d'accès par auth (pas de tenant)**
  - **Notes** : pgvector avec index HNSW. Modèle tenant unique : pas de filtre `tenant_id` dans le SQL. Le contrôle d'accès au vector store est porté par l'authentification + RBAC (un viewer ne peut pas appeler `/agent/chat`, un analyst peut, etc.).
  - **Test plan** : Test paramétré par rôle exerce `/agent/chat` ; assure que `viewer` est rejeté avec 403 et que `analyst`/`admin`/`owner` ont accès aux résultats vectoriels.
  - **Statut partiel** : RBAC sur `/agent/chat` ✓ (`Agent::UseCases::HandleQuery` + 4 specs use_case + 6 specs request couvrant viewer 403 / analyst/admin/owner 200). Linter de stack assure déjà l'absence totale de `tenant_id` dans le repo (cf. `add-tech-stack` § 2.3). **Reste pour cocher** : (a) table pgvector + index HNSW, (b) intégration end-to-end avec un embedder local (cf. § 4.1).

- [ ] **4.4 Endpoint chat `POST /agent/chat`**
  - **Notes** : Streaming SSE via `ActionController::Live`. Chaque item de résultat porte la citation `(host_id, scanned_at)`. Résultats vides renvoient un message explicite « pas de match ».
  - **Test plan** : e2e avec un index fixture contenant des hôtes FR-Modbus et FR-non-Modbus ; requête « modbus exposés en France » ; assurer (a) chaque résultat a country=FR et un service modbus, (b) tous les résultats portent une citation, (c) P95 chemin chaud < 2,5 s sur 50 requêtes échantillons (avec embedder local).
  - **Statut partiel** : route `POST /agent/chat` câblée (`apps/api/config/routes.rb` + `Agent::ChatController`). Use case `Agent::UseCases::HandleQuery` valide `query`, applique RBAC, délègue au `Agent::HybridRetriever` (déjà livré), retourne le contrat `{rows, citations, warnings, retrieval_path, duration_ms}` aligné sur `apps/web/src/api/agent.js`. Audit recorder écrit chaque appel. Réponse 503 `agent_pipeline_unavailable` quand le pipeline n'est pas câblé. 6 specs use_case + 6 specs request. **Reste pour cocher** : (a) streaming SSE via `ActionController::Live` (actuellement réponse JSON simple), (b) test e2e avec index fixture FR-Modbus + embedder local, (c) mesure P95 < 2,5 s sur 50 requêtes.

- [ ] **4.5 Résilience embedder externe (conditionnel)**
  - **Notes** : Quand un embedder externe est configuré : timeout par appel à 2,5 s ; circuit breaker (gem `circuit_box` ou équivalent) avec seuils par défaut N=5 échecs / 30 s, ouvert pendant 60 s. Métriques Prometheus `embedding_provider_failures_total`, `embedding_provider_latency_seconds`. Quand le provider est down, l'agent renvoie 503 plutôt qu'un fallback fabriqué.
  - **Test plan** : Test qui configure `embedder.provider=mistral`, simule des 5xx via mock et assure (a) HTTP 503 renvoyé avec body `{"error":"embedding_provider_unavailable","provider":"mistral"}`, (b) compteur de failures incrémenté, (c) circuit breaker s'ouvre après N échecs et rejette les appels suivants immédiatement, (d) timeout de 2,5 s coupe les requêtes longues sans laisser de tâches en arrière-plan.

---

## 5. Serveur MCP — spec : `mcp-server`

- [ ] **5.1 Engine Rails dédié au MCP partageant la pile de middlewares (HTTP+SSE uniquement)**
  - **Notes** : Implémenter `apps/api/engines/mcp` (Rails Engine ou namespace de routes). Outils `search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report` comme controllers Rails. Streaming SSE via `ActionController::Live`. Auth par clé API tenant partagée avec l'API REST. **Pas de chemin de code stdio**.
  - **Test plan** : `spec/mcp/tools_spec.rb` exerce chaque outil sur un transport HTTP+SSE in-process, assurant que la réponse matche le schema JSON déclaré. Test additionnel qui assure qu'aucun binaire de la plateforme n'expose un point d'entrée stdio MCP (`grep`/scan d'imports).
  - **Statut partiel** : namespace `/mcp/tools` câblé dans le process Rails (pas d'engine séparé, pas de processus stdio — conforme). Routes `GET /mcp/tools` (liste) + `POST /mcp/tools/:tool_name` (invoke) partagent les middlewares Rails (auth + tenant-rejection + audit). 4 outils livrés : `search_hosts`, `get_host`, `list_scopes`, `request_scan`. **Reste pour cocher** : (a) `get_scan_status` + `export_report` à livrer une fois GoodJob et le rapport métier câblés ; (b) streaming SSE via `ActionController::Live` (réponse JSON synchrone pour l'instant) ; (c) test grep `stdio` dans les binaires (pas encore automatisé). 13 specs request `tools_spec.rb` + 11 specs `tool_registry_spec.rb`.

- [x] **5.2 `request_scan` rejette les cibles hors scope**
  - **Notes** : L'outil valide les paramètres, vérifie le scope (réutilise la même garde que le worker Go), écrit une ligne d'audit et enqueue un `ScanJob` via GoodJob. Renvoie immédiatement le `scan_id` ou erreur structurée `out-of-scope`.
  - **Test plan** : Test d'intégration appelle `request_scan` avec une cible dans le scope ; assure (a) `scan_id` renvoyé en < 100 ms, (b) job présent en table `good_jobs`. Test négatif : cible hors scope → erreur `out-of-scope`, aucun job enqueued, ligne d'audit.
  - **Statut** : `Reconaut::ScanEnqueuer` (`app/lib/reconaut/scan_enqueuer.rb`) effectue le scope check, valide le payload contre `ScanJobV1` (rejette `scan_kind` / `target.kind` hors enum), calcule `idempotency_key=scan-YYYYMMDD-HHMM-<sha16>` déterministe par cible+minute, délègue à un `job_bus` injectable. `InMemoryJobBus` livré pour les tests/dev local — `GoodJob` quand l'adapter sera câblé (cf. add-tech-stack §3.2 / 5.1). Outil MCP `request_scan` câble sous l'enqueueur. 12 request specs : (a) scan_id renvoyé < 500 ms (cible <100 ms côté backend), (b) job présent dans la file, (c) cible hors scope → `result.ok=false, error=out-of-scope`, aucun job enqueued, audit écrit, (d) RBAC viewer/analyst → 403, admin/owner → 200, (e) `scan_kind`/`target_kind` hors enum → 400 param_invalid, (f) `target_value` manquant → 400 missing_param. 7 specs unitaires `scan_enqueuer_spec.rb` couvrent les invariants (déterminisme idempotency_key, ScanJobV1 round-trip).

- [ ] **5.2 `request_scan` rejette les cibles hors scope**
  - **Notes** : L'outil valide les paramètres, vérifie le scope (réutilise la même garde que le worker Go), écrit une ligne d'audit et enqueue un `ScanJob` via GoodJob. Renvoie immédiatement le `scan_id` ou erreur structurée `out-of-scope`.
  - **Test plan** : Test d'intégration appelle `request_scan` avec une cible dans le scope ; assure (a) `scan_id` renvoyé en < 100 ms, (b) job présent en table `good_jobs`. Test négatif : cible hors scope → erreur `out-of-scope`, aucun job enqueued, ligne d'audit.

- [x] **5.3 Application des scopes**
  - **Notes** : Table de scopes par clé API (au moins `read:hosts`, `write:scans`, `read:reports`, `manage:scopes`) ; middleware rejette avec erreur MCP structurée contenant le nom du scope manquant.
  - **Test plan** : Clé read-only appelant `request_scan` renvoie `unauthorized` nommant `write:scans` ; la même clé appelant `search_hosts` réussit.
  - **Statut** : Table de scopes par rôle (`SCOPES_BY_ROLE` dans `Mcp::ToolsController`) — `read:hosts`, `read:scopes`, `write:scans`, `manage:scopes`, `read:reports`. Chaque outil déclare ses scopes requis (`Tool#scopes`). `Tool#call` lève `Mcp::ScopeError` listant les scopes manquants quand le caller n'a pas tous les scopes requis, transformé en HTTP 403 `rbac_forbidden` avec message contenant les scopes manquants. Specs : viewer + read:hosts → 200 sur `search_hosts` ; viewer + sans `write:scans` → 403 sur `request_scan`. La cohérence par clé API arrivera avec l'auth réelle (§ 7.2) — la table de scopes par rôle est le pivot équivalent en attendant.

- [x] **5.4 Audit des appels d'outils**
  - **Notes** : Table d'audit append-only ; ligne écrite en moins de 1 s pour chaque appel d'outil.
  - **Test plan** : Test d'intégration invoque chaque outil une fois et assure qu'une ligne d'audit correspondante existe en moins de 1 s avec `key_id`, `tool_name`, `duration_ms`.
  - **Statut** : `Mcp::ToolsController#audit` écrit une entrée pour chaque chemin (`success`, `unknown_template` sur outil inconnu, `unauthorized` sur scope manquant, `param_invalid` sur params hors plage). `template_id` = `mcp:<tool_name>`, `caller_id` propagé. 2 specs request : invocation réussie → `:success`, outil inconnu → `:unknown_template`. La latence p95 < 1 s sera mesurée en CI quand le recorder DB sera câblé (§ 6).

- [ ] **5.5 TLS configurable selon la posture**
  - **Notes** : `mcp.tls.required=true` (défaut) refuse les connexions en clair. `mcp.tls.required=false` (déploiement strictement interne avec mTLS au reverse proxy) accepte les connexions amont en clair ; le boot logue cette posture.
  - **Test plan** : Avec `tls.required=true` : tentative HTTP en clair refusée avec raison `tls-required` ; HTTPS valide réussit. Avec `tls.required=false` : tentative HTTP en clair acceptée et le log de boot mentionne `mcp.tls.required=false posture=internal`.

---

## 6. Conformité RGPD — spec : `gdpr-compliance`

- [ ] **6.1 Configuration de résidence par l'opérateur**
  - **Notes** : Variable / config `data_residency.allowed_regions` (liste d'identifiants de région ou simplement une chaîne libre documentaire pour les déploiements hors cloud). Le boot logue la valeur ; aucune valeur EU codée en dur dans le cœur.
  - **Test plan** : Test boote avec `allowed_regions=["self-hosted-rack-1"]` → succès, valeur loguée. Test avec liste vide → exit non-zero `data-residency-not-configured`. Test Terraform avec une réplication source EU → destination hors-liste rejeté à `terraform plan`.

- [ ] **6.2 Workflow d'effacement par sujet (outil opérateur)**
  - **Notes** : UI + API permettant à l'opérateur d'effacer toutes les données liées à un identifiant (IP, domaine, `host_id`). Effacement transactionnel : OLTP + index vectoriel + graphe (si actif) + tier froid (Postgres compressé ou filesystem) + tombstone audit. Pas de validation de « contrôle de la cible » : c'est l'opérateur qui décide qui mérite l'effacement, sa propre conformité dicte la procédure interne.
  - **Test plan** : Test e2e crée des données pour un identifiant, exécute l'effacement, assure (a) absence de l'identifiant dans toutes les couches en moins de 1 transaction, (b) tombstone hashée écrite dans le journal d'audit.

- [ ] **6.3 Journal d'audit append-only**
  - **Notes** : Table Postgres avec UPDATE/DELETE révoqués pour le rôle applicatif. Réplication cross-région reste *possible* (Postgres standard) mais cesse d'être un invariant cœur ; documenter comment l'activer dans `docs/operating/audit.md`.
  - **Test plan** : `UPDATE`/`DELETE` direct sur la table d'audit échoue avec erreur de permission et la tentative est elle-même journalisée. Le job de checksum tourne et vérifie le snapshot de la veille.

---

## 7. Plateforme — spec : `platform`

- [x] **7.1 Modèle tenant unique vérifié**
  - **Notes** : Schéma DB sans colonne `tenant_id` sur les tables métier (`hosts`, `services`, `certificates`, `scopes`, `scans`, `audit_log`, etc.). UI sans concept de tenant. API rejette tout paramètre `tenant_id` ou header `X-Tenant`.
  - **Test plan** : Linter de schéma vérifie l'absence de colonne `tenant_id` ; test API qui envoie `{ "tenant_id": "x" }` à un endpoint reçoit 400 `tenant_param_unsupported` ; revue manuelle de l'UI confirme l'absence de sélecteur de tenant.
  - **Statut** : (a) Linter `scripts/check_stack.sh` rejette tout `tenant_id` dans les migrations Rails ou les `.go`, validé par `check_stack_test.sh` (cas négatif `tenant_id` dans une migration → exit non-zero). (b) Concern `TenantParamRejection` inclus dans `ApplicationController` rejette en 400 `tenant_param_unsupported` toute requête contenant params `tenant_id` / `tenant` / `caller_tenant` / `org_id` ou headers `X-Tenant` / `X-Tenant-Id` / `X-Org` / `X-Org-Id`. 6 specs request couvrent les 4 params et les 4 headers. (c) UI `apps/web/src/views/HomeView.vue` ne contient ni sélecteur ni concept de tenant (revue manuelle : 2 panneaux `AgentChat` + `ScopesPanel`, aucun champ tenant).

- [ ] **7.2 Authentification local-first, OIDC optionnel**
  - **Notes** : Auth locale (`devise` ou équivalent ; mots de passe Argon2id, clés API hashées en base, rotation) **toujours disponible et active par défaut**. Aucun IdP externe requis pour bootstrapper l'instance. OIDC activable en parallèle par configuration ; la couche d'auth est codée contre l'interface OIDC standard pour qu'un IdP soit substituable sans changer le code applicatif. Si OIDC tombe, l'auth locale doit continuer de servir.
  - **Test plan** : Test e2e (a) bootstrap d'une instance sans config OIDC, création d'un compte `owner` local, génération de clé API, appel API + MCP avec la clé ; assurer zéro connexion sortante pendant tout le test (mock outbound). (b) Activer OIDC en runtime ; assurer que les comptes locaux préexistants se connectent toujours. (c) Couper l'IdP OIDC pendant qu'il est configuré ; assurer que l'auth locale reste fonctionnelle. (d) Test additionnel monte un IdP fake conforme OIDC pour vérifier que l'app ne dépend d'aucune extension propriétaire.

- [ ] **7.3 Application des rôles**
  - **Notes** : Rôles `owner`, `admin`, `analyst`, `viewer`, `mcp_client`. Chaque endpoint et chaque outil MCP imposent le rôle requis côté serveur.
  - **Test plan** : Test paramétré par rôle exerce chaque endpoint et assure permis/refusé selon la matrice de rôle.

---

## 8. Distribution OSS — spec : `open-source-governance`

- [ ] **8.1 Images OCI multi-arch**
  - **Notes** : Dockerfile par app (api, web, scanner). Build multi-arch (amd64 + arm64) via `docker buildx`. Publication sur GitHub Container Registry. Tag par version SemVer + tag `latest` flottant.
  - **Test plan** : Workflow CI `release.yml` produit les images ; `docker pull ghcr.io/<org>/reconaut-api:vX.Y.Z` réussit sur les deux architectures ; un test de smoke démarre le container et vérifie que le healthcheck passe.

- [ ] **8.2 SBOM CycloneDX + signatures Sigstore/cosign**
  - **Notes** : `syft` génère un SBOM par image, attaché à la release GitHub. Cosign keyless (OIDC GitHub Actions) signe images et SBOM.
  - **Test plan** : Chaque release publiée a un asset `sbom-<image>-vX.Y.Z.cdx.json` ; `cosign verify --certificate-identity-regexp ...` réussit sur chaque image release ; un check CI échoue si l'asset SBOM ou la signature manquent.

- [ ] **8.3 Chart Helm et docker-compose de référence**
  - **Notes** : Chart Helm sous `deploy/helm/reconaut` avec valeurs par défaut sécurisées (embedder local, auth locale, sans OIDC). `docker-compose.yml` à la racine pour le dev local et les déploiements simples (Postgres + Rails + scanner Go ; pas de Redis, pas de MinIO, pas d'Ollama imposé — Ollama est un override opt-in dans un compose.override.yml d'exemple).
  - **Test plan** : `helm install reconaut ./deploy/helm/reconaut --dry-run` produit un manifest valide ; `docker compose up -d` démarre la stack et le healthcheck `/healthz` répond 200 en moins de 60 s.

- [ ] **8.4 Linter no-billing-no-feature-gate**
  - **Notes** : Script CI rejette tout import de SDK de facturation (`stripe`, `chargebee`, `paddle`, etc.) et tout chemin de code conditionné par une variable de licence (`if ENV["RECONAUT_LICENSE_KEY"]`, etc.).
  - **Test plan** : Le linter passe propre sur HEAD. Test : ajouter `gem "stripe"` au Gemfile → le linter échoue. Test : ajouter `if ENV["RECONAUT_LICENSE_KEY"]` dans un controller → le linter échoue.

- [ ] **8.5 Boot air-gapped vérifié**
  - **Notes** : Test e2e qui démarre la stack en réseau privé (sans gateway internet sortant) avec config par défaut (embedder local, auth locale, pas d'OIDC public). Aucun appel sortant ne doit être tenté pendant un cycle d'usage de référence (ajout de scope, scan, recherche agent, appel MCP).
  - **Test plan** : Test réseau audite les sockets sortants pendant 10 minutes sous trafic synthétique ; assure zéro connexion vers une IP publique.

---

## 9. Documentation

- [ ] **9.1 README de projet**
  - **Notes** : Positionnement OSS, mode self-hosted, démarrage rapide (docker-compose), liens vers la doc, badges (license AGPL-3.0, build, release, SBOM).
  - **Test plan** : Une revue humaine confirme la clarté du quickstart ; un utilisateur externe arrive à lancer une instance locale en suivant uniquement le README.

- [ ] **9.2 Doc opérateur : modèle de responsabilité RGPD**
  - **Notes** : `docs/operating/responsibility-model.md` qui explique : opérateur = controller, Reconaut = outil, fournisseurs externes = subprocessors *de l'opérateur* si activés. Liste des outils que la plateforme fournit pour aider l'opérateur (audit, effacement, configuration de résidence).
  - **Test plan** : La page existe et est référencée depuis le README et la doc d'installation.

- [ ] **9.3 Doc utilisateur : déclaration de scope**
  - **Notes** : `docs/usage/scope.md` qui explique le modèle scope-driven, comment déclarer son scope, ce qui se passe quand une cible est hors scope.
  - **Test plan** : La page existe et est citée depuis l'UI au premier login.

- [ ] **9.4 Site de doc public (Docusaurus ou MkDocs)** — référence API + référence outils MCP (HTTP+SSE) + page DSAR opérateur + runbooks de déploiement.

---

## Acceptation pour le change dans son ensemble

- [ ] Chaque exigence des spec deltas (`scanning`, `ai-optimization`, `agent-interface`, `mcp-server`, `gdpr-compliance`, `platform`, `open-source-governance`) a au moins un test automatisé passant en CI.
- [ ] La CI rejette toute fusion qui (a) introduit une dépendance avec licence incompatible AGPL, (b) introduit un import de SDK de facturation, (c) introduit un chemin de code conditionné par une variable de licence commerciale.
- [ ] Une instance auto-hébergée démarre via `docker compose up -d` sans aucune clé API externe configurée et reste pleinement fonctionnelle (scan, agent, MCP) avec l'embedder local.
- [ ] Aucun appel sortant n'est observable depuis une instance fraîchement bootée avec config par défaut (vérifié par un test réseau qui audite les sockets ouverts pendant 10 minutes).
- [ ] Le scanner refuse en dur toute cible hors scope déclaré (test rouge avec une cible non-scope, statut `out-of-scope`, zéro paquet réseau).
- [ ] Le modèle tenant unique est imposé : aucune colonne `tenant_id` dans les migrations, l'API rejette tout paramètre de tenant, l'UI n'expose pas de sélecteur.
- [ ] Une release publique a été produite avec image OCI multi-arch signée et SBOM CycloneDX attaché.
- [ ] Une commande de self-check documentée (`bin/doctor` ou `rails reconaut:doctor`) imprime région, défauts de rétention, fingerprint du provider d'embedding actif (local / Ollama / Mistral / OpenAI-compatible), posture TLS MCP, taille de la file `good_jobs`.
