# Spec delta : agent-interface

## ADDED Requirements

### Requirement: Host Indexing Pipeline
La plateforme DOIT alimenter automatiquement la table `embeddings` (cf. `add-embedder-pluggable` §1.1) avec un vecteur par `Host` ingéré. L'indexation s'exécute de manière **asynchrone** via GoodJob — pas d'embedding synchrone dans le hook `ActiveRecord`.

Contraintes :

- **Trigger** : `Host.after_create_commit` ET `Host.after_update_commit` (uniquement pour les champs embedding-pertinents : `ip`, `fqdn`, `last_seen_at`) enqueuent un `IndexHostJob.perform_later(host.id)`.
- **Idempotence** : `IndexHostJob.perform(host_id)` peut être ré-exécuté sans dupliquer la ligne. Implémentation : upsert sur `host_id` (un host = au plus une ligne d'embedding).
- **Text fingerprint déterministe** : pour un host donné dans un état donné, le fingerprint produit est stable (mêmes inputs → mêmes vecteurs). Inclut `ip`, `fqdn`, `first_seen_at`, `last_seen_at`, et la concaténation triée de ses services (`port`, `protocol`, `banner`).
- **Tag provider/model/dim** : chaque ligne `embeddings` porte le `provider`, `model`, `dim` qui a produit le vecteur. Permet à `reconaut:reindex` de détecter les lignes héritées d'un provider précédent.

#### Scenario: Création d'un host → ligne d'embedding apparaît
- **GIVEN** une instance avec l'embedder par défaut (`local`) câblé et le worker GoodJob actif
- **WHEN** un opérateur crée un host via `POST /mcp/tools/ingest_scan_result` ou `Host.create!(ip: "192.0.2.10")`
- **THEN** dans les 5 secondes, une ligne apparaît dans `embeddings` avec `host_id` matchant
- **AND** cette ligne porte `provider="local"`, `dim=384`, `model="stub-384"` (ou équivalent)

#### Scenario: Update d'un champ embedding-pertinent → re-indexation
- **GIVEN** un host existant avec une ligne `embeddings`
- **WHEN** l'opérateur fait `host.update!(fqdn: "new.example.fr")`
- **THEN** un nouveau `IndexHostJob` est enqueueé
- **AND** après exécution, la ligne `embeddings` a un nouveau `vector` (différent de l'ancien) et `indexed_at` actualisé

#### Scenario: Update d'un champ non-embedding (created_at, updated_at) → pas de re-indexation
- **GIVEN** un host existant avec une ligne `embeddings`
- **WHEN** l'opérateur touche un champ non-pertinent (par ex. trigger un `touch`)
- **THEN** aucun `IndexHostJob` n'est enqueueé
- **AND** la ligne `embeddings` reste inchangée (même `vector`, même `indexed_at`)

#### Scenario: IndexHostJob idempotent (retry safe)
- **GIVEN** un host pour lequel `IndexHostJob` a déjà tourné une fois
- **WHEN** le même job est ré-exécuté (retry GoodJob, dédoublonnage manuel, etc.)
- **THEN** la table `embeddings` contient toujours exactement **une** ligne pour ce `host_id`
- **AND** la ligne reflète l'état le plus récent (upsert)

#### Scenario: Embedder externe down → job retry, pas de crash AR
- **GIVEN** `RECONAUT_EMBEDDER_PROVIDER=mistral` et l'API Mistral down (HTTP 502)
- **WHEN** un host est créé
- **THEN** le `Host.create!` réussit (la transaction AR n'attend pas l'embedding)
- **AND** `IndexHostJob` lève une erreur retry-able (`Reconaut::Embedder::UnavailableError`) ; GoodJob retry selon sa politique standard
- **AND** une fois Mistral remonté, le job réussit au prochain retry et la ligne `embeddings` apparaît

### Requirement: VectorRetriever Backed by pgvector
La plateforme DOIT exposer `Agent::VectorRetriever` qui exécute une recherche par similarité cosine dans la table `embeddings` pour répondre aux queries sémantiques. C'est le composant qui transforme `Mcp::ToolRegistry["agent_chat"]` d'un stub vide en un retriever fonctionnel.

Contraintes :

- **Embed query → cosine search** : `call(query)` embed le query texte via l'embedder courant, puis exécute `SELECT host_id, indexed_at FROM embeddings ORDER BY vector <=> $1::vector LIMIT 50`.
- **Mode mono-user strict** : aucun filtre `tenant_id` dans le SQL.
- **Gracieux sur erreur** : embedder down → retourne `[]` + warning consommable par `HybridRetriever`. Table vide → `[]` (pas d'erreur). Dim mismatch → `[]` + warning explicite.
- **Format de retour** : `[{ "host_id" => "...", "scanned_at" => "..." }, ...]` — compatible avec ce que `HybridRetriever` injecte dans sa `Response`.

#### Scenario: Query sémantique retourne les top-N hosts
- **GIVEN** une instance avec 10 hosts indexés et un retriever vectoriel câblé
- **WHEN** un client invoque `POST /mcp/tools/agent_chat` avec `prompt="dns esiea"`
- **THEN** la réponse 200 contient `rows` avec ≤ 50 entrées, chacune portant `host_id` et `scanned_at`
- **AND** `warnings` est vide (ou ne contient PAS `retriever-not-wired`)
- **AND** `retrieval_path = "vector"` (ou `"hybrid"` quand le graph path sera ajouté)

#### Scenario: Table embeddings vide → réponse vide gracieuse
- **GIVEN** une instance fraîchement bootée avec 0 row dans `embeddings`
- **WHEN** un client invoque `agent_chat`
- **THEN** la réponse est 200 avec `rows=[]`, `citations=[]`
- **AND** AUCUNE erreur SQL n'est levée

#### Scenario: Embedder unavailable → 503 via mapping existant
- **GIVEN** l'embedder externe est down (circuit ouvert)
- **WHEN** un client invoque `agent_chat`
- **THEN** la réponse est `503 embedding_provider_unavailable` (mapping fourni par `add-embedder-pluggable` §4)
- **AND** AUCUNE requête SQL pgvector n'est tentée

### Requirement: Pipeline Wired into Registry at Boot
La plateforme DOIT câbler `Reconaut::Registry.default.hybrid_retriever` au boot Rails (production / development) avec un `HybridRetriever` réel quand Postgres + extension `vector` + table `embeddings` sont disponibles. Sinon, retomber gracieusement sur le `StubRetriever` (cf. commit 94afc76) sans bloquer le boot.

Contraintes :

- **`Reconaut::Agent::Pipeline.build(registry:)`** retourne un `HybridRetriever` câblé : `VectorRetriever` + `NullRouter` (force vector-only) + `NullTemplateExecutor` (retourne empty).
- **Initializer Rails** `agent_pipeline.rb` `after_initialize` :
  - Si `Embedding.table_exists?` ET embedder ready → pose le retriever réel.
  - Sinon → log warn + laisse `nil` (le `StubRetriever` du commit 94afc76 prend le relais).
- **Skip en `Rails.env.test?`** — les specs câblent leur propre retriever via fixtures.

#### Scenario: Boot dev nominal → retriever câblé
- **GIVEN** une instance dev avec Postgres + migration `create_embeddings_table` appliquée + embedder local
- **WHEN** `bundle exec rails server` démarre
- **THEN** un log `[agent] pipeline wired (provider=local dim=384)` apparaît
- **AND** `Reconaut::Registry.default.hybrid_retriever.class == Agent::HybridRetriever`
- **AND** `agent_chat` retourne des `rows` réels (pas de `retriever-not-wired` warning)

#### Scenario: Boot sans Postgres → fallback StubRetriever
- **GIVEN** une instance dev sans Postgres (ou table `embeddings` absente)
- **WHEN** Rails boot
- **THEN** un log warn `[agent] pipeline not wired (...)` apparaît
- **AND** `Registry.default.hybrid_retriever` est `nil`
- **AND** `agent_chat` continue à répondre 200 avec `warnings=["retriever-not-wired"]` (comportement gracieux du commit 94afc76)

### Requirement: Reindex Rake Task
La plateforme DOIT exposer une rake task `bundle exec rails reconaut:reindex` qui re-vectorise tous les hosts existants. Utile après changement de provider/dim (les lignes héritées d'un provider précédent ont des vecteurs incompatibles).

Options de la task :

- `RECONAUT_REINDEX_PURGE=true` : `DELETE FROM embeddings WHERE provider != current_provider` AVANT de réindexer.
- `RECONAUT_REINDEX_FILTER='ip:192.0.2.%'` : filtre SQL `LIKE` sur `hosts.ip` ou `hosts.fqdn`.

#### Scenario: reindex complet après changement de provider
- **GIVEN** 10 hosts indexés avec `provider=local dim=384`, opérateur switch sur `provider=mistral dim=384`
- **WHEN** `RECONAUT_REINDEX_PURGE=true bundle exec rails reconaut:reindex`
- **THEN** les 10 lignes héritées sont supprimées
- **AND** 10 nouvelles lignes apparaissent avec `provider="mistral"`
- **AND** `agent_chat` retourne des résultats cohérents (matche la sémantique réelle des hosts)

#### Scenario: reindex idempotent sans purge
- **GIVEN** 10 hosts indexés avec le provider courant
- **WHEN** `bundle exec rails reconaut:reindex` sans `--purge`
- **THEN** les 10 lignes existantes sont mises à jour (upsert), `indexed_at` actualisé
- **AND** aucune ligne dupliquée n'apparaît

### Requirement: Doctor Reports Embedding Pipeline Health
La task `bundle exec rails reconaut:doctor` DOIT exposer un check `embedding_pipeline` qui inclut le nombre de hosts indexés, le total, et la dernière indexation. Permet à l'opérateur de voir d'un coup d'œil si le pipeline est en retard.

#### Scenario: Doctor imprime l'état du pipeline
- **GIVEN** une instance avec 100 hosts dont 90 indexés
- **WHEN** `bundle exec rails reconaut:doctor` est exécutée
- **THEN** la sortie JSON contient `{"name":"embedding_pipeline","status":"info","details":{"indexed_hosts":90,"total_hosts":100,"ratio":0.9,"last_indexed_at":"..."}}`

#### Scenario: Doctor gracieux si table absente
- **GIVEN** une instance sans table `embeddings` (migration non appliquée)
- **WHEN** `reconaut:doctor` est exécutée
- **THEN** le check `embedding_pipeline` retourne `status: "unknown"` avec un détail explicite (`"table embeddings absente"`)
- **AND** AUCUNE exception n'est remontée
