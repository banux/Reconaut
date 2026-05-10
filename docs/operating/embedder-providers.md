# Choisir et configurer son embedder

Statut : **stable**.
Audience : opérateur qui démarre une instance Reconaut.

Reconaut indexe les hôtes dans une table `embeddings` (vecteurs `vector(384)` + index HNSW pgvector) pour permettre à l'agent de répondre aux requêtes en langage naturel via une recherche sémantique. Le **provider d'embedding** qui calcule ces vecteurs est pluggable — quatre implémentations sont livrées avec un sélecteur 12-factor.

## Vue d'ensemble

| Provider              | Réseau sortant | Souveraineté         | Latence typique | Coût     | Config minimale                                                                            |
|-----------------------|----------------|----------------------|-----------------|----------|--------------------------------------------------------------------------------------------|
| `local` (défaut)      | **Aucun**      | 100 % locale         | ~5 ms / batch   | Zéro     | `RECONAUT_EMBEDDER_PROVIDER=local`                                                         |
| `ollama`              | Sidecar local  | Locale (sidecar)     | ~50-200 ms      | Zéro     | `RECONAUT_EMBEDDER_PROVIDER=ollama` + `RECONAUT_EMBEDDER_OLLAMA_URL` + `..._MODEL`         |
| `mistral`             | API EU         | UE (Mistral hosting) | ~200-500 ms     | Pay-per  | `RECONAUT_EMBEDDER_PROVIDER=mistral` + `RECONAUT_EMBEDDER_MISTRAL_API_KEY`                 |
| `openai-compatible`   | API tierce     | Selon endpoint       | ~200 ms-2 s     | Pay-per  | `RECONAUT_EMBEDDER_PROVIDER=openai-compatible` + `..._BASE_URL` + `..._API_KEY` + `..._MODEL` |

Le défaut `local` est conçu pour un opérateur qui veut démarrer **sans aucune dépendance externe** — l'index sémantique fonctionne tout de suite, la qualité est suffisante pour les requêtes opérateur courantes, et **aucun paquet ne sort** du cluster.

## Provider `local` (défaut)

Encodage déterministe SHA-256 projeté sur 384 dimensions. Pas de modèle ML embarqué en v1 (le choix d'un modèle réel — `nomic-embed-text` ONNX, `bge-small-en-v1.5` GGUF — est différé).

```sh
# Pas besoin de variables : c'est le défaut.
# Pour expliciter :
export RECONAUT_EMBEDDER_PROVIDER=local
export RECONAUT_EMBEDDER_LOCAL_DIM=384  # optionnel, défaut 384
```

**Garantie zéro réseau.** Un test (`spec/lib/reconaut/embedder/contract_spec.rb`) stubbe `Net::HTTP.start → boom` et confirme que `Local.embed` complète sans erreur. Si tu vois du trafic sortant après avoir choisi `local`, ouvre une issue.

## Provider `ollama`

Reconaut parle au sidecar Ollama via HTTP. L'opérateur héberge Ollama dans le même réseau (typiquement docker-compose ou un cluster Kubernetes voisin).

```sh
export RECONAUT_EMBEDDER_PROVIDER=ollama
export RECONAUT_EMBEDDER_OLLAMA_URL=http://ollama:11434
export RECONAUT_EMBEDDER_OLLAMA_MODEL=nomic-embed-text
```

Le boot **échoue** (`embedder-misconfigured`) si `URL` ou `MODEL` est absent.

**Modèles recommandés** : `nomic-embed-text` (768 dim — réduire à 384 via projection) ou `mxbai-embed-large` (1024 dim — idem). Note : la table `embeddings` est figée à `vector(384)` ; un modèle de dim plus grande produit une erreur d'insertion. Cf. *Changer la dim* ci-dessous.

## Provider `mistral`

API EU hébergée par Mistral (souveraineté UE par défaut).

```sh
export RECONAUT_EMBEDDER_PROVIDER=mistral
export RECONAUT_EMBEDDER_MISTRAL_API_KEY=msk-XXXX
export RECONAUT_EMBEDDER_MISTRAL_MODEL=mistral-embed   # optionnel
```

Le boot **échoue** si `API_KEY` est absent.

**Latence et résilience.** Les appels Mistral peuvent prendre 200 ms à 2 s. Reconaut applique un **timeout strict** (2.5 s par défaut) et un **circuit breaker** (5 échecs / 30 s ouvre 60 s). Quand le circuit est ouvert, `/agent/chat` répond `503 embedding_provider_unavailable` immédiatement — **pas** de fallback fabriqué.

## Provider `openai-compatible`

Endpoint générique compatible OpenAI (LM Studio, vLLM, llama.cpp server, OpenRouter, etc.).

```sh
export RECONAUT_EMBEDDER_PROVIDER=openai-compatible
export RECONAUT_EMBEDDER_OPENAI_BASE_URL=http://lmstudio.local:1234/v1
export RECONAUT_EMBEDDER_OPENAI_API_KEY=sk-anything-or-empty
export RECONAUT_EMBEDDER_OPENAI_MODEL=nomic-embed-text-v1.5
```

Toutes trois requises. Le `BASE_URL` doit pointer vers le préfixe `/v1` du serveur compatible (le code appelle `/v1/embeddings`).

## Variables de résilience (s'appliquent aux 3 providers réseau)

| Variable                                    | Défaut | Effet                                                          |
|---------------------------------------------|--------|----------------------------------------------------------------|
| `RECONAUT_EMBEDDER_TIMEOUT_S`               | `2.5`  | Timeout par appel `embed`. Au-delà → `TimeoutError`.            |
| `RECONAUT_EMBEDDER_BREAKER_FAILURES`        | `5`    | Échecs consécutifs qui ouvrent le circuit.                     |
| `RECONAUT_EMBEDDER_BREAKER_WINDOW_S`        | `30`   | Fenêtre glissante pour compter les échecs.                     |
| `RECONAUT_EMBEDDER_BREAKER_OPEN_S`          | `60`   | Durée d'ouverture du circuit avant essai en `:half_open`.       |

Le provider `local` n'est PAS wrappé — il n'a pas de réseau, pas de besoin.

## Vérifier la config

```sh
$ bundle exec rails reconaut:doctor | jq '.checks[] | select(.name == "embedder_health")'
{
  "name": "embedder_health",
  "status": "info",
  "details": {
    "provider": "local",
    "dim": 384,
    "circuit_state": "closed",
    "failures_total": 0
  }
}
```

`circuit_state` ∈ {`closed`, `open`, `half_open`}. `failures_total` est un compteur in-memory cumulatif depuis le boot (réinitialisé au redémarrage).

## Changer la dim (modèle non-384)

La table `embeddings` est figée à `vector(384)`. Pour utiliser un modèle qui émet des vecteurs de dimension différente :

1. Joue une migration custom :
   ```ruby
   change_column :embeddings, :vector, "vector(768)"
   execute "DROP INDEX IF EXISTS idx_embeddings_vector_hnsw"
   execute "CREATE INDEX idx_embeddings_vector_hnsw ON embeddings USING hnsw (vector vector_cosine_ops)"
   ```
2. Re-vectorise tous les hôtes existants (les anciens vecteurs sont incompatibles).
3. Mets à jour `RECONAUT_EMBEDDER_LOCAL_DIM` ou la config provider en conséquence.

Multi-modèles simultanés (un index par dim) est différé à un futur change `add-multi-model-embeddings`.

## Comportement en cas de panne provider

Quand le provider externe est down (timeout, 5xx, circuit ouvert) :

- `/agent/chat` répond **HTTP 503** avec body :
  ```json
  {
    "error": "embedding_provider_unavailable",
    "provider": "ollama",
    "reason": "circuit-open",
    "message": "embedder-circuit-open: provider=ollama"
  }
  ```
- `reason` ∈ {`timeout`, `circuit-open`, `backend-unavailable`}.
- Aucune réponse fabriquée n'est renvoyée. L'opérateur sait immédiatement que la cause est externe, pas applicative.
- Une ligne d'audit est écrite (`template_id=mcp:agent_chat`) — le 503 n'est pas silencieux.

## Liens

- `openspec/changes/add-embedder-pluggable/` — change qui livre table + résilience + boot validation + doctor.
- `openspec/changes/init-reconaut-platform/specs/agent-interface/spec.md` — spec parente (Requirements `Embedder Resilience`, `Vector Storage`, `Boot Validation`).
- `apps/api/app/lib/reconaut/embedder.rb` — interface + sélecteur 12-factor.
