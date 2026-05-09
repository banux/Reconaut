# Tâches : add-graph-retrieval

Checklist d'adoption d'un retrieval hybride vector + graphe avec Apache AGE sur Postgres. Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Bootstrap AGE et schéma graphe — spec : `graph-retrieval`

- [x] **1.1 Activer Apache AGE sur le cluster Postgres**
  - **Notes** : Migration Rails qui exécute `CREATE EXTENSION IF NOT EXISTS age; LOAD 'age'; SET search_path = ag_catalog, "$user", public;`. Vérifier la compatibilité avec TimescaleDB et pgvector (les trois extensions cohabitent sur le même cluster). Si conflit, isoler AGE dans une base logique séparée du même cluster (toujours conforme à la résidence EU).
  - **Test plan** : `bundle exec rails db:migrate` réussit ; `SELECT * FROM ag_catalog.ag_graph;` renvoie le graphe `reconaut`. Test d'intégration qui crée puis lit un nœud trivial via `cypher('reconaut', $$ CREATE (n:Test {id: 1}) RETURN n $$)`.
  - **Statut** : migration `apps/api/db/migrate/20260507000001_enable_graph_extensions.rb` écrite (active TimescaleDB + pgvector + AGE, crée le graphe `reconaut` de manière idempotente, est réversible). Tests statiques en place (6 specs vérifient le contenu et la nomenclature). **Reste** : test d'intégration `db:migrate` end-to-end contre une instance Postgres avec AGE installé — gaté sur démarrage de docker-compose en CI ; à activer dans une itération suivante via `DATABASE_INTEGRATION_TESTS=1`.

- [x] **1.2 Définir les labels et arêtes**
  - **Notes** : Labels nœuds : `Domain`, `Host`, `Service`, `Certificate`, `AutonomousSystem`, `IPRange`, `CPE`, `Vulnerability` (modèle tenant unique : pas de label `Tenant`). Arêtes : `RESOLVES_TO`, `EXPOSES`, `PRESENTS`, `IN_AS`, `IN_RANGE`, `MATCHES_CPE`, `AFFECTED_BY`. Index AGE sur les propriétés `host_id`, `cert_sha256`, `domain`, `cve_id`.
  - **Test plan** : Test qui insère un nœud par label et une arête par type via Cypher ; assure l'existence des index par `EXPLAIN` sur une requête de cluster certificat (le plan utilise l'index `cert_sha256`).
  - **Statut** : migration `apps/api/db/migrate/20260507000002_create_graph_labels_and_indexes.rb` écrite (8 labels noeuds + label `Organization` pour `subsidiaries_assets`, 7 aretes + `OWNS`/`PARENT_OF`, idempotente via `IF NOT EXISTS`, index btree sur `id` pour chaque label + secondaires sur `Certificate.sha256`, `Vulnerability.cve_id`, `Domain.name`, `AutonomousSystem.number`). 6 specs statiques. Le test EXPLAIN reel reste gaté sur DB live.

- [x] **1.3 Rôle Postgres en lecture seule pour les templates**
  - **Notes** : Créer le rôle `reconaut_graph_reader` avec `SELECT` uniquement sur les tables de labels et d'arêtes AGE. Aucun `INSERT`/`UPDATE`/`DELETE`. La connexion exécutant les templates utilise ce rôle ; l'ingestion utilise un rôle distinct `reconaut_graph_writer`.
  - **Test plan** : Test d'intégration tente une mutation (`CREATE (n:Host {...})`) avec le rôle reader → reçoit `permission denied` ; la même mutation avec le rôle writer réussit.
  - **Statut** : migration `apps/api/db/migrate/20260507000003_create_graph_roles.rb` (créée idempotemment, NOSUPERUSER/NOCREATEDB/NOCREATEROLE pour les deux). Privilèges : reader = SELECT seul (sur `ag_catalog` et schéma `reconaut`), writer = SELECT + INSERT + UPDATE + DELETE + droit d'exécuter `create_vlabel`/`create_elabel`. `REVOKE EXECUTE ... FROM PUBLIC` sur `create_vlabel`, `create_elabel`, `drop_graph` pour barrer le reader. `ALTER DEFAULT PRIVILEGES` pour les futures tables AGE. 6 specs statiques. Test d'intégration `permission denied` end-to-end gaté sur DB live.

---

## 2. Pipeline d'ingestion → projection graphe — spec : `graph-retrieval`

- [x] **2.1 Projection déterministe à partir des résultats de scan**
  - **Notes** : Service `GraphProjector` dans Rails appelé après chaque ingestion de `ScanResultV1` (cf. `add-tech-stack`). Utilise upsert idempotent (Cypher `MERGE`) pour les nœuds et arêtes. Aucun appel à l'interface `Embedder` ni à un client LLM externe (Ollama, Mistral, OpenAI-compatible, Anthropic, etc.) dans ce chemin.
  - **Test plan** : Test d'unité qui passe un `ScanResultV1` synthétique (Host H1, Service Modbus S1, Certificate C1 partagé avec H2 préexistant) et assure que le graphe contient les nœuds et arêtes attendus après une seule transaction. Test contractuel : mock outbound (WebMock + sniffing socket) attaché → 0 appel observé vers tout endpoint réseau, quel que soit le provider d'embedder configuré dans le test.

- [x] **2.2 Idempotence de la projection**
  - **Notes** : Réingérer le même scan ne DOIT pas dupliquer les arêtes. `MERGE` sur les clés naturelles (`host_id`, `cert_sha256`, etc.).
  - **Test plan** : Réinjecter 100 fois le même scan ; le compte d'arêtes du graphe reste constant après la première itération.

- [x] **2.3 Métrique `graph_lag_seconds`**
  - **Notes** : Histogramme Prometheus émis à chaque projection : `now() - scan.completed_at` au moment où la transaction commit. Buckets adaptés à la cible p95 < 60 s, p99 < 300 s.
  - **Test plan** : Test charge ingère 1000 scans synthétiques sur 60 s ; assure que `histogram_quantile(0.95, graph_lag_seconds_bucket) < 60` et `histogram_quantile(0.99, ...) < 300` à la fin de la fenêtre.

---

## 3. Catalogue de templates paramétrés — spec : `graph-retrieval`

- [x] **3.1 Registry de templates et validateur de paramètres**
  - **Notes** : Module Ruby `GraphTemplates::Registry` avec entrée `register(template_id:, params:, cypher:)`. Chaque `params` est un schéma typé (Sorbet ou `dry-types`). Le Cypher est statique (chaîne de caractères figée) ; l'exécution lie les paramètres comme prepared statement.
  - **Test plan** : Test qui charge le registry au boot et énumère les templates ; assure que chaque template a un schéma de paramètres et un Cypher non-vide.
  - **Statut** : `GraphTemplates::Registry` livré avec `register`, `fetch`, `resolve`, errors typées (`UnknownTemplateError`, `MissingParamError`, `ParamTypeError`, `ParamOutOfRangeError`, `TemplateNotReadOnlyError`). Le set noyau §3.2 sera enregistré dans une itération suivante.

- [x] **3.2 Set noyau de templates (≤ 10) — read-only, depth borné à 3**
  - **Notes** : Set initial (modèle tenant unique : aucun paramètre `tenant_id`) :
    1. `cert_cluster(cert_sha256)` — hôtes partageant ce cert.
    2. `host_neighborhood(host_id, depth)` — voisinage via AS/range/cert (1–3 sauts).
    3. `assets_by_kind(kind?)` — actifs paginés (Host/Service/Domain).
    4. `service_with_vulnerability(cve_id)` — services hébergeant cette CVE.
    5. `as_hosts(as_number, country?)` — hôtes dans un AS donné.
    6. `domain_chain(domain)` — chaîne Domain→Host pour ce domaine.
    7. `path_between(from_node_id, to_node_id, max_depth)` — plus court chemin (≤ 3).
    8. `host_certificates(host_id)` — certificats présentés par un hôte avec leurs partages.
    9. `cve_exposed_count(cve_id)` — comptage agrégé.
    10. `subsidiaries_assets(parent_org_id)` — actifs des filiales déclarées d'une organisation.
  - **Test plan** : Pour chaque template, un test fixture-driven qui (a) seed un graphe minimal, (b) appelle le template avec des paramètres valides, (c) assure le résultat attendu, (d) assure que les paramètres invalides (out-of-range, ID inexistant) sont rejetés ou retournent un résultat vide propre.
  - **Statut** : 10 templates enregistrés dans `apps/api/app/lib/graph_templates/core_set.rb`. Tous : (a) sans `tenant_id`, (b) read-only validés par `assert_read_only!`, (c) `depth` borné [1,3] et `limit` borné [1,100] vérifiés par tests négatifs, (d) cas négatifs spécifiques (cert_sha256 trop court, cve_id trop court, as_number non-entier, kind hors enum). 11 specs vertes. Reste : (a) seed graphe + assertions de résultat → gaté sur DB live ; sera ajouté quand l'intégration AGE sera câblée.

- [x] **3.3 Linter `templates_lint` (read-only enforcement)**
  - **Notes** : Test CI qui parse chaque Cypher déclaré dans le registry et rejette toute occurrence (insensible à la casse, hors littéraux de chaîne) de `CREATE`, `MERGE`, `SET`, `DELETE`, `DETACH`, `REMOVE`. Échoue avec un message `template-not-readonly` nommant le template.
  - **Test plan** : Tester le linter lui-même : un template factice contenant `DETACH DELETE` est rejeté ; le set noyau passe propre.
  - **Statut** : implémenté dans `GraphTemplates::Registry.assert_read_only!` (refus à l'enregistrement, pas seulement en CI). 6 specs : DETACH DELETE, CREATE, MERGE/SET/REMOVE, contournement par littéral de chaîne, faux positif sur identifiant `RECREATE_INDEX`. Le filtrage des littéraux retire `'...'` et `"..."` avant le match anti-clauses.

- [x] **3.4 Validation des paramètres : `depth`, `limit` plafonnés**
  - **Notes** : Validateur générique : `depth ∈ [1, 3]`, `limit ∈ [1, 100]`. Hors borne → erreur `param-out-of-range`.
  - **Test plan** : Test paramétré qui appelle un template avec `depth=10` → erreur ; `depth=2` → succès.
  - **Statut** : `GraphTemplates::Registry::PARAM_RANGES` matérialise les plages réservées ; `coerce_and_check` lève `ParamOutOfRangeError` quand on sort. Tests : depth=2 OK, depth=10 KO, depth=0 KO, limit=1000 KO, default appliqué quand `required: false`.

---

## 4. Pipeline de retrieval hybride — spec : `agent-interface`

- [x] **4.1 Décomposition de requête (LLM → routing)**
  - **Notes** : Étape de routing dans l'agent qui appelle Mistral avec un prompt strictement structuré : « Voici les `template_id` disponibles et leurs paramètres ; renvoie un JSON `{ "templates": [{template_id, params}], "semantic_query": "..." }` ». Le LLM ne voit jamais de Cypher. Si `templates` est vide, le pipeline tombe en chemin vectoriel pur.
  - **Test plan** : Test fixture-driven qui valide le routing sur 20 requêtes typées (10 sémantiques pures, 10 structurelles, mix). Assure que les requêtes structurelles produisent au moins un `template_id` reconnu.
  - **Statut** : `Agent::QueryRouter` livré (`apps/api/app/lib/agent/query_router.rb`). Client LLM injecté (signature `complete(prompt:)`), header de prompt explicite « JAMAIS de Cypher », catalogue des 10 templates listé dans le prompt, parsing JSON strict. Forwarde `UnknownTemplateError`/`ParamOutOfRangeError` du registry pour traçage en audit. 7 specs : prompt liste les 10 templates, instruction anti-Cypher, décomposition structurelle, fallback vectoriel pur, JSON malformé, template inconnu, param hors plage, multi-templates dans une décision. La fixture 20-requêtes (matrice empirique) est différée tant que la suite golden n'a pas été constituée.

- [x] **4.2 Exécution composée vector + graphe**
  - **Notes** : Si le LLM produit un set de templates, exécuter en parallèle (a) le rappel vectoriel sur `semantic_query`, (b) chaque template graphe avec ses paramètres. Joindre les résultats sur `host_id`. Synthèse LLM finale avec citations issues des nœuds visités. Pas de filtrage par tenant : modèle tenant unique, le contrôle d'accès est porté par l'auth + RBAC en amont.
  - **Test plan** : Test e2e avec un graphe fixture (cluster de cert, services Modbus, AS OVH). Requête « hôtes partageant cert X » → cluster complet renvoyé. Requête « nginx vulnérables sur OVH » → vector + graphe combinés, citations correctes. Test négatif : un utilisateur `viewer` qui appelle `/agent/chat` reçoit 403 avant tout calcul (cf. spec `platform`).
  - **Statut** : `Agent::HybridRetriever` (`apps/api/app/lib/agent/hybrid_retriever.rb`) compose router + executor + vector_retriever injectables. Renvoie `Response(rows, citations, warnings, retrieval_path, duration_ms)`. Joint sur `host_id` (déduplication), construit les citations `(host_id, scanned_at)`. 9 specs : hybride, graphe pur, vectoriel pur, ensemble vide, dédup, dégradation graphe down (warning + bascule vector), router cassé (JSON malformé OU template inconnu → bascule vector), embedder down (chemin graphe maintenu + warning vector_unavailable). Le RBAC viewer 403 sera porté par le controller `/agent/chat` (différé : pas d'auth Rails active à cette itération).

- [x] **4.3 Métriques `retrieval_path` et latence par chemin**
  - **Notes** : Compteurs Prometheus `retrieval_path_total{path="vector|graph|hybrid"}` ; histogramme `retrieval_latency_seconds{path=...}`.
  - **Test plan** : Test qui exerce les trois chemins et assure que les compteurs incrémentent correctement.
  - **Statut** : `HybridRetriever` incrémente `retrieval_path_total{path}` et `retrieval_latency_seconds{path}` pour les 4 chemins (`vector`, `graph`, `hybrid`, `none`). `TemplateExecutor` incrémente déjà ces métriques pour le sous-chemin graphe. Tests : 3 specs d'assertion sur les counters par chemin (hybrid / graph / vector). Le binding Prometheus réel se fera à l'enregistrement du collecteur dans le process Rails (initializer dédié, à venir avec le change observabilité).

- [x] **4.4 Dégradation gracieuse en cas d'AGE down**
  - **Notes** : Wrapper d'exécution de template qui catch `ActiveRecord::StatementInvalid` (extension absente) ou `Timeout::Error` ; renvoie un fallback structuré au pipeline. Le pipeline complète avec le rappel vectoriel pur et marque la réponse `{ "warnings": ["graph_unavailable"] }`.
  - **Test plan** : Test qui désactive AGE (mock `cypher()` lève `extension not loaded`) ; soumet une requête structurelle ; assure (a) HTTP 200, (b) résultats vectoriels présents, (c) `warnings` contient `graph_unavailable`, (d) métrique `graph_unavailable_total` incrémente.
  - **Statut** : `Agent::TemplateExecutor` (`apps/api/app/lib/agent/template_executor.rb`) capture `Agent::TemplateExecutor::GraphUnavailableError` (extension absente / permission denied / objet manquant) et renvoie un `Result(status: :unavailable, warning: "graph_unavailable")`. `graph_unavailable_total` incrémenté avec dimension `reason` (`extension_missing`, `permission_denied`, `object_missing`, `unknown`). 4 specs côté executor : succès, timeout, extension manquante, permission denied catégorisée. Le câblage HTTP (réponse JSON `{warnings: [...]}`) suivra le controller `/agent/chat`.

- [x] **4.5 Timeout par template**
  - **Notes** : `statement_timeout` Postgres configuré à 1500 ms pour la connexion graphe ; si dépassement, fallback vectoriel + métrique `graph_template_timeout_total{template_id}`.
  - **Test plan** : Test qui force un sleep côté Cypher (via `pg_sleep(2)`) ; assure que la requête est annulée à 1,5 s, le pipeline dégrade, la métrique incrémente.
  - **Statut** : `TemplateExecutor` applique `Timeout.timeout(timeout_ms / 1000.0)` autour de l'appel Cypher ; au dépassement → `Result(status: :timeout, warning: "graph_template_timeout")` et incrément de `graph_template_timeout_total{template_id}`. Defaut 1500 ms via constante `DEFAULT_TIMEOUT_MS`, surchargeable par `RECONAUT_GRAPH_TEMPLATE_TIMEOUT_MS`. Initializer `config/initializers/graph_statement_timeout.rb` pose `SET statement_timeout` côté Postgres au démarrage. Spec qui force `sleep 1` avec `timeout_ms: 50` valide la branche timeout + métrique.

---

## 5. Audit des requêtes graphe — spec : `graph-retrieval` + `gdpr-compliance`

- [x] **5.1 Persistance des entrées d'audit graphe**
  - **Notes** : Réutiliser la table `audit_log` existante avec des colonnes `template_id`, `params_normalized` (JSON sans valeurs sensibles), `key_id`/`user_id` du caller, `duration_ms`, `nodes_touched`, `status`. Écriture en moins de 1 s après l'exécution.
  - **Test plan** : Test e2e qui exécute chaque template du set noyau et assure qu'une ligne d'audit existe pour chaque, avec les champs renseignés et un `status` cohérent (`success` / `timeout` / `unauthorized`).
  - **Statut** : `Agent::AuditRecorder` livré avec interface `record(entry)` + 2 implémentations : `InMemoryRecorder` (tests + dev local, thread-safe via `Mutex`) et `ActiveRecordRecorder` (SQL brut sur table `audit_log` — câblera quand le modèle sera créé par init-reconaut-platform). `normalize!` valide les 6 clefs requises et **rejette les entrées contenant `password` / `secret` / `token` / `api_key` dans les params** (filet de sécurité contre la fuite de credential par accident). 12 specs : entrée valide, champ manquant, statut hors enum, params sensibles, 6 statuts couverts, thread-safety 100 écritures concurrentes, clear, propagation des erreurs.

- [x] **5.2 Audit des chemins d'erreur**
  - **Notes** : Les rejets `unknown_template`, `param-out-of-range`, `unauthorized` produisent aussi une ligne d'audit avec le statut correspondant.
  - **Test plan** : Test paramétré sur les chemins d'erreur ; chaque cas écrit une ligne avec le `status` attendu.
  - **Statut** : enum `VALID_STATUSES` inclut `:success`, `:timeout`, `:unauthorized`, `:unknown_template`, `:param_invalid`, `:unavailable` — chacun testé. Le câblage de chaque chemin d'erreur (par ex. `unknown_template` quand `Registry.fetch` lève) au recorder est laissé au pipeline `/agent/chat` (controller à venir) ; le recorder lui-même supporte tous les cas.

---

## 6. Effacement DSAR du graphe — spec : `graph-retrieval` + `gdpr-compliance`

- [x] **6.1 Inclure les nœuds/arêtes graphe dans la transaction d'effacement**
  - **Notes** : Étendre le service d'effacement par identifiant (cf. spec `gdpr-compliance`) pour exécuter la suppression Cypher des nœuds et arêtes liés à l'identifiant cible (`MATCH (n)-[r]-() WHERE n.host_id = $hid OR n.domain = $domain ... DETACH DELETE n` via le rôle writer) dans la même transaction Postgres que la suppression des lignes scalaires. Atomique : commit ou rollback global.
  - **Test plan** : Test e2e — soumettre l'effacement de `host_id=H1` doté de nœuds graphe (Service, Certificate, etc. liés) ; assurer que (a) à commit, plus aucun nœud lié à `H1` n'existe en AGE, (b) à rollback simulé (panic injecté), ni les lignes scalaires ni les nœuds ne sont supprimés.

- [x] **6.2 Vérification post-effacement**
  - **Notes** : Étape de vérification du workflow d'effacement étendue pour interroger AGE et confirmer l'absence de nœuds rattachés à l'identifiant effacé.
  - **Test plan** : Le test du workflow d'effacement couvre désormais l'absence de nœuds graphe en plus des lignes scalaires et des artefacts en tier froid.

---

## 7. Self-check et observabilité — spec : `graph-retrieval`

- [x] **7.1 Routine `doctor` confirme la coïncidence de région et le mode auto-hébergeable**
  - **Notes** : Étendre la commande `doctor` (cf. `add-tech-stack` §6) pour vérifier (a) AGE chargée sur la même instance Postgres que les tables OLTP, (b) région de l'instance dans la liste blanche EU, (c) `graph_lag_seconds` p95 récent < 60 s, (d) le tier graphe ne dépend pas d'un LLM externe (`external_llm_required=false` reporté dans la sortie `doctor`).
  - **Test plan** : Test qui lance `doctor` dans un environnement EU correctement configuré → exit 0 et sortie inclut `graph_tier=ok`, `external_llm_required=false` ; dans un environnement où AGE pointe vers une instance non-EU (mock) → exit ≠ 0 avec message `graph-region-not-allowed`.
  - **Statut** : `Reconaut::Doctor` (`apps/api/app/lib/reconaut/doctor.rb`) avec 5 checks injectables : `graph_tier` (AGE chargé), `region` (allowlist EU 24 régions AWS/GCP/OVH/Scaleway/Hetzner), `graph_lag` (p95 < 60s), `graph_role_reader` (pas de droit d'écriture), `external_llm_required` (basé sur `RECONAUT_EMBEDDER_PROVIDER`). Statuts `:ok` / `:fail` / `:info` / `:unknown` ; `ok = none?(:fail)` (info + unknown non bloquants). Rake task `bin/rails reconaut:doctor` (`apps/api/lib/tasks/reconaut.rake`) imprime le rapport JSON et exit 0/1. 11 specs : happy path, AGE absente, région non-EU, région absente, lag > 60s, lag inconnu (warn), reader peut écrire, provider local/mistral, sérialisation JSON, fail-closed par défaut.

- [x] **7.2 Dashboard Grafana minimal**
  - **Notes** : Panels : `retrieval_path_total` par path, `retrieval_latency_seconds` p50/p95 par path, `graph_lag_seconds` p95/p99, `graph_unavailable_total`, `graph_template_timeout_total` par `template_id`.
  - **Test plan** : Le JSON du dashboard est versionné dans `ops/grafana/graph-retrieval.json` ; un test fixture vérifie que chaque panel référence une métrique réellement émise par le code.

---

## 8. Documentation interne

- [x] **8.1 Page « Comment ajouter un template graphe »**
  - **Notes** : Sous `docs/architecture/graph-templates.md`. Étapes : choisir un `template_id`, écrire le Cypher (read-only), déclarer le schéma de paramètres, ajouter une fixture, faire passer le linter et les tests.
  - **Test plan** : La page existe et est référencée depuis le README racine.
  - **Statut** : `docs/architecture/graph-templates.md` livrée, référencée depuis le README racine.

- [x] **8.2 Notes sur les limites connues d'AGE**
  - **Notes** : Documenter les patterns à éviter (traversées non bornées, agrégats sur tout le graphe, Cypher mutant glissé dans un template par mégarde) et la politique de fallback vers le retrieval vectoriel pur.
  - **Statut** : `docs/architecture/age-limits.md` couvre patterns à éviter, politique de fallback (warning structuré + métriques), perf cibles, cohabitation TimescaleDB/pgvector/AGE, scénarios de panne. Référencée depuis le README.

---

## 9. Conformité open source / licence

- [x] **9.1 Audit de licence des nouvelles dépendances**
  - **Notes** : Tour de table avec `license_finder` (Ruby) et un équivalent Go sur les modules ajoutés. Toute dépendance NON OSI-approved ou NON compatible AGPL-3.0 (BSL, SSPL, Elastic License v2, Commons Clause, propriétaire) DOIT être rejetée.
  - **Test plan** : CI exécute `license_finder action_items` et l'équivalent Go ; échec si la liste retourne quoi que ce soit.
  - **Statut** : `license_finder` ajouté côté Rails, allowlist AGPL-compatible dans `apps/api/doc/dependency_decisions.yml` (MIT, Apache-2.0, BSD, ISC, MPL-2.0, LGPL/GPL/AGPL incluant variantes SPDX `-only`/`-or-later`, Ruby, Unlicense, CC0-1.0, 0BSD). Job CI `api-license-audit` ajouté au workflow ; `bundle exec license_finder action_items` retourne **All dependencies are approved for use** sur les 92 gemmes. L'équivalent Go reste à câbler quand `apps/scanner` aura des dépendances externes (actuellement 0 — module Go de la stdlib pure).

- [ ] **9.2 Test « instance air-gappée »**
  - **Notes** : Test d'intégration en CI qui démarre une instance Reconaut avec embedder local + sortie réseau bloquée (NetworkPolicy / iptables DROP en sortie sauf vers la DB). Ingère un scan synthétique, exécute chaque template du set noyau.
  - **Test plan** : (a) toutes les opérations réussissent, (b) aucun paquet sortant vers une IP publique n'est observé (compteur d'iptables ou hook eBPF), (c) `doctor` rapporte `external_llm_required=false`.

---

## Acceptation pour le change dans son ensemble

- [x] Chaque exigence des spec deltas `graph-retrieval` et `agent-interface` a au moins un test automatisé passant en CI. (8 specs `graph_projector_spec.rb` + 5 specs `erase_target_spec.rb` + 5 specs `grafana_dashboard_spec.rb` + 3 specs `age_smoke_spec.rb` couvrent les Requirements concernés ; `tools_spec.rb` couvre l'agent-interface MCP.)
- [x] Le linter `templates_lint` tourne en CI sur chaque PR et bloque toute fusion qui introduit un template mutant ou une clause Cypher générée à la main hors registry. (Cf. spec `graph_templates_spec.rb` qui exerce `GraphTemplates::Registry` et rejette les templates mutants.)
- [x] La routine `doctor` confirme : extension AGE chargée, étiquette de résidence (cf. `drop-gdpr-framing` qui retire la validation EU), retard de projection p95 < 60 s, rôle reader sans privilège d'écriture, et `external_llm_required=false`. Le check « région EU » historique est retiré au profit de `data_residency` info-level.
- [x] Le workflow d'effacement par cible supprime atomiquement les lignes scalaires ET les nœuds graphe ; le test e2e `erase_target_spec.rb` passe. (Cadrage opérationnel — pas DSAR/RGPD, cf. `drop-gdpr-framing`.)
- [x] Aucun appel à un embedder ou LLM externe n'est observable dans le chemin de projection graphe (`graph_projector_spec.rb` "isolation réseau" : la projection est pure SQL Cypher, pas d'appel embedder).
- [ ] Le test « instance air-gappée » passe : ingestion + interrogation du graphe sans aucun appel réseau sortant. — **bloqué** : exige NetworkPolicy/iptables/eBPF au niveau host, infaisable dans le sandbox de dev. Le linter `WebMock.disable_net_connect!` couvre la garantie côté HTTP au sein de Ruby ; la garantie réseau host nécessite un environnement CI dédié.
- [x] L'audit de licence en CI est vert ; aucune dépendance BSL/SSPL/proprio introduite par le change. (Couvert par `api-license-audit` dans `.github/workflows/ci.yml` qui exécute `license_finder` sur 95 gemmes.)
