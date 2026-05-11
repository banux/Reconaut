# Change : add-embedding-pipeline

## Pourquoi

`add-embedder-pluggable` a livré l'**interface** (4 providers + résilience) et la **table** `embeddings` (pgvector + HNSW). `add-agent-chat-streaming` a livré le **transport** SSE. Mais entre les deux, **rien ne vectorise les hôtes** et **rien ne câble le `HybridRetriever` réel** dans le `Registry`. Conséquences observées en dev :

1. La table `embeddings` reste vide après ingestion d'hôtes — aucun pipeline d'indexation n'écrit dedans.
2. `Registry.default.hybrid_retriever` est nil par défaut. Le patch fix d'urgence (commit 94afc76) registre les tools avec un `StubRetriever` qui retourne `rows=[], warnings=["retriever-not-wired"]` — le tool MCP `agent_chat` répond 200 mais sans aucune donnée applicative.
3. L'opérateur qui pose une question sémantique (`liste moi les DNS ESIEA`) reçoit une réponse vide même si les hôtes correspondants existent en base.

Ce change ferme la boucle : pipeline d'indexation déclenché à la création des hôtes + retriever vectoriel branché sur la table `embeddings` + câblage dans le `Registry` au boot Rails. Après ce change, `agent_chat` retourne de vrais résultats (la qualité sémantique dépend du provider choisi — local SHA-256-projeté donne du déterministe sans sens sémantique, Ollama/Mistral donnent du vrai vecteur).

## Ce qui change

1. **`Reconaut::EmbeddingIndexer`** — service `Reconaut::EmbeddingIndexer.index!(host)` qui :
   - Calcule un **text fingerprint** déterministe à partir de `Host` + ses `Service` : `"#{host.ip} #{host.fqdn} first_seen=#{...} last_seen=#{...}\nservice: port=... protocol=... banner=...\n..."`.
   - Appelle l'embedder courant (`Reconaut::Registry.default.embedder.embed(texts: [text])`).
   - Upsert dans `embeddings` (un host = au plus une ligne ; remplace si déjà présent pour le même `host_id`).
   - Tagge la ligne avec `provider`, `model`, `dim` courants pour permettre une migration ultérieure.

2. **Hook AR `Host` → indexation async** :
   - `Host.after_create_commit :enqueue_embedding_index!`
   - `Host.after_update_commit :enqueue_embedding_index!` quand un champ embedding-pertinent change (ip, fqdn, last_seen_at).
   - Le hook appelle `IndexHostJob.perform_later(host.id)` (GoodJob).
   - `IndexHostJob` est idempotent — si l'embedder est down, le job retry naturellement via GoodJob.

3. **`Agent::VectorRetriever`** — implémentation `call(query)` qui :
   - Embed la query via `Registry.default.embedder.embed(texts: [query])`.
   - `SELECT host_id, indexed_at AS scanned_at FROM embeddings ORDER BY vector <=> $1::vector LIMIT 50`.
   - Retourne `[{ "host_id" => "...", "scanned_at" => "..." }, ...]` — format aligné sur ce que `HybridRetriever` consomme.
   - En cas d'erreur (embedder down, table vide, dim mismatch), retourne `[]` et logge un `warning` consommable par `HybridRetriever`.

4. **`Reconaut::Agent::Pipeline.build(registry:)`** — factory qui assemble :
   - `vector_retriever = Agent::VectorRetriever.new(embedder: registry.embedder)`
   - `template_executor = Agent::TemplateExecutor::Null.new` (no graph path en v1 — `add-graph-retrieval-cypher-runner` futur).
   - `router = Agent::QueryRouter::VectorOnly.new` (no LLM router — `add-agent-router-llm` futur). Force toujours `decision.semantic_query = user_query`.
   - Retourne un `Agent::HybridRetriever` câblé.

5. **Câblage dans Registry au boot** — initializer `agent_pipeline.rb` (`after_initialize`) qui appelle `Pipeline.build` quand Postgres + extension `vector` + table `embeddings` sont prêtes, et pose le résultat dans `Registry.default.hybrid_retriever`. Si une dépendance manque, log un warning et laisse `nil` (le `StubRetriever` du commit 94afc76 prend le relais — comportement gracieux).

6. **Rake task `reconaut:reindex`** — re-vectorise tous les hosts existants. Utile après changement de provider/dim (les anciennes lignes restent en base mais ont une dim incompatible). Options : `--purge` pour vider d'abord, `--filter='ip:192.0.2.%'` pour cibler.

7. **Doctor enrichi** — `check_embedding_pipeline` retourne `{indexed_hosts, total_hosts, ratio, last_indexed_at}`. Statut `:info` si tous les hosts sont indexés, `:unknown` si la table n'existe pas ou est vide.

8. **Documentation** — `docs/operating/embedding-pipeline.md` documente : flux d'indexation (création de host → job → ligne dans `embeddings`), comment réindexer après changement de provider, comportement quand l'embedder est down, hooks ActiveRecord, limitations actuelles (mono-thread).

## Contraintes

- **Pas de migration de schéma**. La table `embeddings` existe déjà (cf. `add-embedder-pluggable` §1.1). Ce change ne modifie pas le schéma — il alimente la table et la requête.
- **Indexation asynchrone via GoodJob**. Pas d'embedding synchrone dans le hook AR (sinon une création de Host bloque sur un appel Mistral 2s+). Le job tourne dans le worker GoodJob standard.
- **Idempotence stricte**. `IndexHostJob.perform(host_id)` peut être ré-exécuté sans dupliquer la ligne ; l'upsert sur `host_id` garantit "au plus une ligne par host". GoodJob retry automatique = pas de duplicate.
- **Pas de breaking change sur `HybridRetriever`**. Le pipeline construit avec `NullRouter` + `NullExecutor` + `VectorRetriever` respecte l'interface existante. Les tests `hybrid_retriever_spec.rb` ne sont pas touchés.
- **Pas de filtre `tenant_id`** dans les requêtes pgvector. Mode mono-user (cf. `single-user-only`).
- **Pas de dépendance externe**. `pgvector` est déjà activé. `Reconaut::Embedder` est déjà livré. Aucune gem nouvelle.
- **AGPL clean**. Pas d'audit de licence à refaire.

## Non-objectifs (hors scope de ce change)

- **Graph path / Cypher runner réel** — relève de `add-graph-retrieval-cypher-runner` futur. En v1 le `template_executor` est un Null qui retourne empty.
- **LLM-backed query routing** — relève de `add-agent-router-llm` futur. En v1 le router force toujours le chemin vector-only.
- **Re-indexation auto sur changement de service** — quand un `Service` est créé/modifié, le `Host` parent n'est pas re-indexé automatiquement en v1. Différé à `add-embedding-on-service-change`.
- **Vector clustering / threshold de pertinence** — la query retourne les top-N sans filtrer par score cosine minimum. Différé à `add-relevance-threshold`.
- **Re-ranking croisé** — si vector ET graph retournent des résultats, pas de scoring composite. Différé.
- **Multi-modèles en parallèle** — un seul provider à la fois. Différé à `add-multi-model-embeddings`.
- **Backfill streaming pour > 100k hosts** — la rake `reindex` charge tout en mémoire ; OK pour les volumes Reconaut v1 (< 50k hosts par instance). Différé.
- **Métriques Prometheus** d'indexation — différé à `add-prometheus-metrics`.
- **Pipeline d'embedding pour les services pris isolément** — la v1 indexe au niveau host (un host = un vecteur). Indexer chaque service séparément relève de `add-service-level-embedding`.

## Décisions prises

1. **Indexation au niveau host, pas service**. Un Host = un vecteur. Le text fingerprint concatène les services associés. Plus simple, moins de lignes, query plus rapide. Si l'opérateur veut indexer chaque service séparément, c'est `add-service-level-embedding` futur.
2. **`NullRouter` + `NullExecutor`** plutôt que de retarder ce change jusqu'à ce que le pipeline LLM + Cypher soit complet. Le retriever vector-only répond déjà à 80% des requêtes opérateur. Pattern *"livrer la couche utile dès maintenant, étendre plus tard"*.
3. **Hook AR sur `after_create_commit` + `after_update_commit`** plutôt qu'un cron de re-indexation périodique. L'opérateur veut voir l'host immédiatement après ingestion ; un cron horaire serait surprenant.
4. **`IndexHostJob` GoodJob** plutôt qu'un appel synchrone. Un embedder externe peut prendre 2s+ ; bloquer une transaction AR sur du réseau externe = anti-pattern.
5. **Upsert par `host_id`** (un host = une ligne). Pas d'historique des vecteurs anciens. Quand l'opérateur change de provider, soit il `reindex --purge` (recommandé), soit il vit avec des lignes héritées d'un provider précédent (incompatibles → recherche vide).
6. **Doctor reporte le ratio indexed/total** comme indicateur de santé du pipeline. Un opérateur qui voit 50/1000 indexed sait que les jobs sont en retard ou ont échoué.

## Différé (non bloquant, parqué pour plus tard)

- **`add-graph-retrieval-cypher-runner`** : Cypher runner réel sur Apache AGE (template_executor non-Null).
- **`add-agent-router-llm`** : QueryRouter backé par un LLM (Mistral / OpenAI-compatible) qui décompose la query en sous-requêtes graphe + sémantique.
- **`add-embedding-on-service-change`** : trigger re-indexation host quand un service change.
- **`add-relevance-threshold`** : filtre cosine minimum + re-ranking.
- **`add-multi-model-embeddings`** : indexation parallèle multi-provider, requête A/B.
- **`add-service-level-embedding`** : un vecteur par service au lieu d'un par host.
- **`add-embedding-backfill-stream`** : reindex streaming pour > 100k hosts (lazy enumeration via `find_each`).
- **`add-prometheus-metrics`** : compteurs `embedding_index_total`, `vector_query_total`, `vector_query_duration_seconds`.
