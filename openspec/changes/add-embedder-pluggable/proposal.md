# Change : add-embedder-pluggable

## Pourquoi

`init-reconaut-platform` §4.x livre l'interface `Reconaut::Embedder` avec quatre implémentations (`Local`, `Ollama`, `Mistral`, `OpenAICompatible`) et un sélecteur 12-factor (`Embedder.build(env:)`). Le contrat unitaire est couvert (16 specs `contract_spec`, 8 specs `build_spec`), mais **trois pièces manquent pour rendre l'embedder utilisable en production** :

1. **Pas de table de stockage des vecteurs.** L'extension `pgvector` est activée par `add-graph-retrieval` mais aucune table `embeddings` n'existe — l'agent ne peut donc pas indexer ou rechercher sémantiquement. `Reconaut::HybridRetriever` retourne aujourd'hui des résultats stub côté `Agent::HybridRetriever::Response`.
2. **Pas de protection contre les pannes externes.** Quand le provider est `mistral`, `ollama` ou `openai-compatible`, un appel HTTP qui timeout ou retourne 5xx remonte tel quel — pas de timeout strict, pas de circuit breaker, pas de mapping 503 propre. Un Mistral qui ralentit fige toute requête `/agent/chat` sur 30 s par défaut.
3. **Pas de validation au boot ni de visibilité opérationnelle.** `Embedder.build` lève `MisconfiguredError` quand la config est incomplète, mais cette erreur n'est appelée qu'à la première requête — un opérateur qui configure mal le provider ne le découvre qu'au premier appel `/agent/chat`. Et `reconaut:doctor` ne montre pas quel provider est actif ni l'état du circuit breaker.

Ce change ferme ces trois trous **sans modifier l'interface `Reconaut::Embedder` existante** ni casser les tests en place. Il prépare aussi le terrain pour un futur `add-ollama-integration-test` (test live container) et `add-prometheus-metrics` (instrumentation).

## Ce qui change

1. **Migration `create_embeddings_table`** : table Postgres `embeddings(id uuid pk, host_id uuid fk hosts.id on delete cascade, content text not null, vector vector(<dim>) not null, provider text not null, model text not null, dim integer not null, indexed_at timestamp default now())` avec index HNSW sur `vector` (`vector_cosine_ops`). La dimension est fixée par migration à 384 par défaut (alignée sur `Reconaut::Embedder::DEFAULT_LOCAL_DIM`) ; un opérateur qui change de provider avec une `dim` différente DOIT re-vectoriser (cf. doc).

2. **Wrapper de résilience `Reconaut::Embedder::Resilient`** : décorateur qui enveloppe les implémentations externes (`Ollama`, `Mistral`, `OpenAICompatible`) — pas `Local`, qui est in-process. Apporte :
   - **Timeout strict** par appel : `RECONAUT_EMBEDDER_TIMEOUT_S` (défaut 2.5 s). Au-delà, lève `Reconaut::Embedder::TimeoutError`.
   - **Circuit breaker** maison (sans dépendance externe) : N=5 échecs / 30 s ouvre le circuit pour 60 s. Pendant l'ouverture, `embed` lève immédiatement `Reconaut::Embedder::CircuitOpenError` sans toucher au backend.
   - **Compteurs in-memory** : `failures_total`, `circuit_state`, `last_error` exposés via `#stats` pour `reconaut:doctor`. Pas de Prometheus dans ce change (différé).
   - Les seuils sont configurables via env (`RECONAUT_EMBEDDER_BREAKER_FAILURES`, `RECONAUT_EMBEDDER_BREAKER_WINDOW_S`, `RECONAUT_EMBEDDER_BREAKER_OPEN_S`).

3. **`Embedder.build` enveloppe automatiquement les providers réseau** dans un `Resilient` quand le provider ∈ {ollama, mistral, openai-compatible}. `Local` reste exempt (zéro réseau, déjà rapide).

4. **Validation au boot** : initializer `embedder_validation.rb` qui appelle `Reconaut::Embedder.build(env: ENV)` au démarrage Rails et **fait échouer le boot avec exit ≠ 0** si la config est invalide. Message clair listant la variable manquante. Cohérent avec le test plan §4.2(b) qui exige `embedder-misconfigured` au boot pour `ollama` sans URL.

5. **Mapping 503 dans `Agent::ChatController`** : quand `embed` lève `UnavailableError`, `TimeoutError` ou `CircuitOpenError`, le controller retourne **HTTP 503** avec body `{"error":"embedding_provider_unavailable","provider":"<name>","reason":"<short>"}` — cohérent avec le test plan §4.5(a). Aucun fallback fabriqué.

6. **`reconaut:doctor` enrichi** d'un check `embedder_health` : provider actif + dim + état circuit breaker (`closed | open | half_open`) + count `failures_total` accumulé.

7. **Spec `agent-interface` enrichie** d'un Requirement *Embedder Resilience* qui formalise les contraintes (timeout, breaker, mapping 503).

## Contraintes

- **Interface `Embedder` inchangée**. `embed(texts:) -> Array<Array<Float>>` + `dim` + `provider` restent identiques. Le wrapper `Resilient` implémente la même interface (substitution Liskov).
- **Pas d'appel sortant pour `Local`**. Le wrapper de résilience n'enveloppe PAS `Local` — c'est inutile (in-process) et le test §4.1(iv) qui stubbe `Net::HTTP.start → boom` doit continuer à passer.
- **Pas de dépendance externe pour le circuit breaker**. Implémentation maison ~50 lignes (compteur d'échecs + horloge). Ajouter `circuit_box` ou `stoplight` ferait basculer la décision audit_dependencies AGPL — non justifié pour un état aussi simple.
- **Pas de Prometheus dans ce change**. Les compteurs sont exposés via `#stats` (Hash) pour `reconaut:doctor`. L'export Prometheus arrivera dans `add-prometheus-metrics` quand le pipeline d'observabilité sera en place.
- **Mode mono-user respecté**. Pas de filtre `tenant_id` sur la table `embeddings`.
- **AGPL clean**. La migration ne réintroduit aucune dépendance externe non-OSI.

## Non-objectifs (hors scope de ce change)

- **Streaming SSE pour `/agent/chat`** — relève de `add-agent-chat-streaming` (§4.4a).
- **Test live contre un container `ollama/ollama` éphémère** — relève de `add-ollama-integration-test`. Le container test exige docker disponible en CI, qui n'est pas garanti aujourd'hui.
- **Métriques Prometheus** (`embedding_provider_failures_total`, `embedding_provider_latency_seconds`) — relève de `add-prometheus-metrics`. Le change actuel expose des compteurs Hash via `#stats`.
- **Benchmark P95 < 2.5 s sur 50 requêtes** — relève de `add-agent-perf-baseline`. Nécessite un fixture index FR-Modbus + un environnement de mesure stable.
- **Indexation automatique des hôtes** (cron, hook on-create) — la table est créée mais le pipeline d'indexation arrive avec `add-embedding-pipeline`. Pour ce change, l'opérateur indexe manuellement via un futur outil MCP `embedding_index` ou un job ad-hoc.
- **Multi-modèles simultanés** (un index par dim) — pas en v1. Une instance = un provider = une dim = une table.

## Décisions prises

1. **Circuit breaker maison** plutôt qu'une gem. ~50 lignes Ruby, pas de transitive dependency, audit AGPL trivial. Les gems matures (`stoplight`, `circuit_box`) ajoutent un store Redis qu'on ne veut pas (cf. invariant "no external broker").
2. **Timeout 2.5 s par défaut** — aligné sur le test plan §4.5 et sur l'objectif de réactivité opérateur. Configurable via env pour les déploiements où le provider est lent (Mistral en heure de pointe peut prendre 4-5 s).
3. **HNSW plutôt que IVFFlat**. HNSW est l'index de référence pgvector ≥ 0.5, qualité supérieure, requête plus rapide. Le coût mémoire est acceptable pour les volumes Reconaut (< 1M hôtes par instance v1).
4. **Dim figée à 384 dans la migration**. Tous les providers livrés peuvent émettre du 384 (`mistral-embed` est en 1024, mais l'opérateur peut spécifier `dim=384` pour un modèle adapté). Si un opérateur a besoin de 768 ou 1024, il joue une migration custom — documenté dans la doc d'install.
5. **Boot fail-fast sur misconfiguration**. Plutôt que de logguer un warning et de mourir au premier `/agent/chat`, on échoue au boot. Un opérateur qui voit un container Rails qui crashloop comprend tout de suite ; un container qui boot OK mais renvoie 500 sur la première requête est plus traître.
6. **`Resilient` enveloppe AUTOMATIQUEMENT les providers réseau**. L'opérateur n'a rien à activer manuellement — la résilience est on-by-default pour les providers externes. Le code applicatif (`HybridRetriever`, `ChatController`) appelle `embedder.embed(...)` sans se soucier du wrapping.

## Différé (non bloquant, parqué pour plus tard)

- **`add-ollama-integration-test`** : test contre un container `ollama/ollama` réel en CI (gated par disponibilité docker).
- **`add-prometheus-metrics`** : exporte `embedding_provider_failures_total` et `embedding_provider_latency_seconds` au format Prometheus quand l'observabilité OTel sera en place (cf. init §1.3).
- **`add-agent-chat-streaming`** : SSE via `ActionController::Live` pour `/agent/chat`.
- **`add-embedding-pipeline`** : worker qui (re)vectorise les hôtes en batch, hook on-create, gestion des changements de provider/dim.
- **`add-multi-model-embeddings`** : si un opérateur veut comparer plusieurs modèles côte-à-côte (table par dim, sélecteur par requête).
- **`add-agent-perf-baseline`** : benchmark P95 < 2.5 s sur 50 requêtes contre un fixture index FR-Modbus.
