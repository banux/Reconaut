# Pipeline d'embedding

Statut : **stable**.
Audience : opérateur Reconaut qui veut comprendre comment ses hôtes deviennent recherchables sémantiquement.

Ce document décrit comment Reconaut alimente la table `embeddings` (vecteurs sémantiques par hôte) et comment `agent_chat` les consomme pour répondre aux requêtes en langage naturel.

## Flux d'indexation

```
   Host.create!   ──▶  after_create_commit hook  ──▶  IndexHostJob (GoodJob)
                                                          │
                                                          ▼
                                              Reconaut::EmbeddingIndexer.index!(host)
                                                          │
                                                          ▼
                                              embedder.embed(texts: [fingerprint])
                                                          │
                                                          ▼
                                              UPSERT INTO embeddings (host_id, vector, ...)
```

1. **Création d'un host** (via `POST /mcp/tools/ingest_scan_result` ou ingestion interne) → `Host.create!` enqueue un `IndexHostJob`.
2. **Update d'un champ pertinent** (`ip`, `fqdn`, `last_seen_at`) → re-indexation enqueueé. Les updates non-pertinents (`updated_at`, etc.) sont ignorés.
3. **`IndexHostJob` async** lit l'host, calcule le **text fingerprint** (`"#{ip} #{fqdn}\nfirst_seen=... last_seen=...\nservice: port=... protocol=... banner=..."`) et appelle l'embedder.
4. **Upsert** : un host = au plus une ligne d'embedding. Retry GoodJob sûr.

## Quand l'embedder est down

`IndexHostJob` retry automatique via GoodJob :

| Erreur                                | Retry config                   |
|----------------------------------------|---------------------------------|
| `Reconaut::Embedder::UnavailableError` | 5 tentatives, wait 30s          |
| `Reconaut::Embedder::TimeoutError`     | 3 tentatives, wait 30s          |
| `Reconaut::Embedder::CircuitOpenError` | 5 tentatives, wait 60s          |

La création de Host **n'attend jamais** l'embedding (l'embedder externe peut prendre 2s+ ; bloquer une transaction AR serait un anti-pattern). Si l'embedder reste down trop longtemps, l'host existe en base mais sans ligne `embeddings` — `agent_chat` le retournera dans une recherche future, dès que le pipeline rattrape.

## Réindexer manuellement

Cas typiques où une réindexation complète est nécessaire :

- Changement de provider (`local` → `ollama` → `mistral`).
- Changement de dimension (rare ; nécessite aussi une migration custom de la colonne `vector(384)`).
- Embedder down pendant une période et les jobs ont épuisé leurs retries.

Commande :

```sh
# Réindexe tous les hosts avec le provider courant
bundle exec rails reconaut:reindex

# Purge d'abord les embeddings d'un provider antérieur, puis réindexe
RECONAUT_REINDEX_PURGE=true bundle exec rails reconaut:reindex

# Cible un sous-ensemble (ip ou fqdn LIKE pattern)
RECONAUT_REINDEX_FILTER='ip:192.0.2.%' bundle exec rails reconaut:reindex
RECONAUT_REINDEX_FILTER='fqdn:%.example.fr' bundle exec rails reconaut:reindex
```

La rake task est **idempotente** : sans `RECONAUT_REINDEX_PURGE`, elle upsert les lignes existantes (mise à jour de `vector` + `indexed_at`) sans dupliquer.

## Vérifier la santé du pipeline

```sh
bundle exec rails reconaut:doctor | jq '.checks[] | select(.name == "embedding_pipeline")'
```

Sortie typique :

```json
{
  "name": "embedding_pipeline",
  "status": "info",
  "details": {
    "indexed_hosts": 47,
    "total_hosts": 50,
    "ratio": 0.94,
    "last_indexed_at": "2026-05-11T08:15:00Z"
  }
}
```

`ratio < 1.0` ⇒ certains hosts ne sont pas indexés. Causes possibles :

- Jobs en queue (GoodJob saturé) — vérifier la file via `SELECT count(*) FROM good_jobs WHERE finished_at IS NULL;`.
- Jobs en échec définitif (5 retries épuisés) — log Rails montre `[embedding] enqueue failed`.
- Embedder down — `reconaut:doctor` montre `embedder_health.circuit_state=open`.

Action recommandée : `bundle exec rails reconaut:reindex` après remontée de l'embedder.

## Troubleshooting

### `agent_chat` retourne `rows=[]` mais j'ai des hosts en base

Possibilités :

1. **Pipeline pas câblé** : `Reconaut::Registry.default.hybrid_retriever` est nil. Causes : extension pgvector pas installée, table `embeddings` absente. Vérifier avec `reconaut:doctor` (le check `embedding_pipeline` retourne `status=unknown`).
2. **Table `embeddings` vide** : les jobs n'ont pas tourné (GoodJob worker pas lancé) ou le hook AR ne s'est pas déclenché (créations en dehors de Rails — par ex. directement en SQL). Lancer `bundle exec rails reconaut:reindex`.
3. **Provider/dim mismatch** : les lignes ont été indexées avec un provider d'une dim différente. La requête pgvector silent-fail et retourne `[]`. Solution : `RECONAUT_REINDEX_PURGE=true bundle exec rails reconaut:reindex`.

### `agent_chat` retourne `warnings: ["retriever-not-wired"]`

Le `StubRetriever` est actif (le fallback du commit 94afc76). Le boot Rails n'a pas réussi à câbler le `HybridRetriever` réel. Cherche `[agent] pipeline not wired` dans les logs Rails au démarrage.

## Limitations actuelles (v1)

- **Mono-thread**. L'indexation tourne dans le worker GoodJob standard. Pour 100k+ hosts, plusieurs workers en parallèle accélèrent (chacun consomme la file).
- **Pas de re-index sur changement de service**. Quand un `Service` est créé/modifié, le `Host` parent n'est PAS re-indexé automatiquement. Workaround : `host.touch(:last_seen_at)` après un changement de service massif. Différé à `add-embedding-on-service-change`.
- **Indexation au niveau host**. Un host = un vecteur. Indexer chaque service séparément relève de `add-service-level-embedding`.
- **Pas de re-ranking croisé** vector + graphe. La v1 est vector-only. Le router graph + LLM viendra avec `add-graph-retrieval-cypher-runner` et `add-agent-router-llm`.

## Liens

- `openspec/changes/add-embedding-pipeline/` — change qui livre la plomberie.
- `openspec/changes/add-embedder-pluggable/` — providers embedder + résilience.
- [`docs/operating/embedder-providers.md`](embedder-providers.md) — configurer un provider externe.
- `apps/api/app/lib/reconaut/embedding_indexer.rb` — service d'indexation.
- `apps/api/app/lib/agent/vector_retriever.rb` — recherche pgvector.
