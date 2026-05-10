# Spec delta : agent-interface

## ADDED Requirements

### Requirement: Vector Storage with pgvector + HNSW
La plateforme DOIT exposer une table Postgres `embeddings` qui persiste les vecteurs sémantiques des hôtes, indexée par HNSW (cosine), permettant à l'agent de répondre aux requêtes en langage naturel via une recherche vectorielle.

La table DOIT comporter :

- `id` (uuid pk)
- `host_id` (uuid fk hosts.id, ON DELETE CASCADE) — la suppression d'un hôte purge ses vecteurs
- `content` (text) — le matériel textuel embarqué (banner, services agrégés, métadonnées)
- `vector` (vector(384)) — la représentation embedding ; dimension figée à 384 par défaut
- `provider` (text) — `local` | `ollama` | `mistral` | `openai-compatible`
- `model` (text) — identifiant du modèle utilisé (ex. `mistral-embed`, `nomic-embed-text`)
- `dim` (integer) — la dimension réelle du vecteur (sanity-check vs la colonne `vector(384)`)
- `indexed_at` (timestamp default now())

Aucune colonne `tenant_id` (mode mono-user, cf. `single-user-only`).

Un index HNSW DOIT exister sur `vector` avec `vector_cosine_ops` pour permettre la recherche `ORDER BY vector <=> $1 LIMIT N` en O(log N).

#### Scenario: Migration crée la table avec extension pgvector activée
- **GIVEN** une base Postgres avec l'extension `vector` activée
- **WHEN** `bin/rails db:migrate` est exécutée
- **THEN** la table `embeddings` existe avec les colonnes attendues (vérifiable via `\d embeddings`)
- **AND** un index `idx_embeddings_vector_hnsw` de type `hnsw (vector vector_cosine_ops)` existe
- **AND** ni `embeddings.tenant_id` ni aucune autre colonne tenant n'est présente (linter `check_stack.sh` reste vert)

#### Scenario: Suppression d'un hôte purge ses vecteurs (CASCADE)
- **GIVEN** un hôte `h1` avec une ligne dans `embeddings` rattachée à son `id`
- **WHEN** l'hôte `h1` est supprimé via `Host.find(h1).destroy`
- **THEN** la ligne correspondante dans `embeddings` est supprimée par cascade
- **AND** aucun orphelin ne reste

#### Scenario: Index HNSW utilisé par EXPLAIN
- **GIVEN** une table `embeddings` peuplée de 100 vecteurs
- **WHEN** une requête `SELECT host_id FROM embeddings ORDER BY vector <=> $1 LIMIT 10` est exécutée
- **THEN** `EXPLAIN` mentionne l'index `idx_embeddings_vector_hnsw` (Index Scan, pas Seq Scan)

### Requirement: Embedder Resilience
La plateforme DOIT protéger l'application des défaillances des embedders externes via timeout strict, circuit breaker et mapping HTTP 503 propre. La résilience DOIT être on-by-default pour les providers réseau (`ollama`, `mistral`, `openai-compatible`) et NE DOIT PAS s'appliquer au provider `local` (in-process, déjà rapide).

Les contraintes :

- **Timeout** : `RECONAUT_EMBEDDER_TIMEOUT_S` (défaut 2.5 s) par appel `embed`. Au-delà, lève `Reconaut::Embedder::TimeoutError`.
- **Circuit breaker** : N=5 échecs consécutifs sur fenêtre glissante de 30 s ouvre le circuit pour 60 s. Pendant l'ouverture, `embed` lève immédiatement `Reconaut::Embedder::CircuitOpenError` sans toucher au backend. Seuils configurables via `RECONAUT_EMBEDDER_BREAKER_FAILURES`, `RECONAUT_EMBEDDER_BREAKER_WINDOW_S`, `RECONAUT_EMBEDDER_BREAKER_OPEN_S`.
- **Mapping 503** : `Agent::ChatController` rattrape `UnavailableError`, `TimeoutError`, `CircuitOpenError` et renvoie HTTP **503** avec body `{"error":"embedding_provider_unavailable","provider":"<name>","reason":"<short>"}`. Aucun fallback fabriqué — l'opérateur reçoit une erreur explicite et corrigeable.
- **Visibilité** : le wrapper expose `#stats` (Hash) avec `failures_total`, `circuit_state` ∈ {`closed`, `open`, `half_open`}, `last_error` (texte court). `reconaut:doctor` lit `#stats` et l'imprime sous le check `embedder_health`.

#### Scenario: Provider externe down → 503 avec body explicite
- **GIVEN** un embedder configuré sur `ollama` avec une URL pointant vers un endpoint qui retourne HTTP 502
- **WHEN** une requête `POST /agent/chat` est traitée
- **THEN** la réponse HTTP est `503 Service Unavailable`
- **AND** le body JSON est `{"error":"embedding_provider_unavailable","provider":"ollama","reason":"<short>"}`
- **AND** un audit log est écrit avec `template_id=agent:chat, status=success` (l'invocation a abouti, le résultat est négatif — cohérent avec out-of-scope)

#### Scenario: Timeout strict de 2.5 s
- **GIVEN** un embedder externe qui répond en 5 s
- **WHEN** le wrapper invoque `embed`
- **THEN** après 2.5 s ± 100 ms, `Reconaut::Embedder::TimeoutError` est levée
- **AND** aucune goroutine/thread n'est laissée derrière (la requête HTTP est annulée, pas seulement détachée)

#### Scenario: Circuit breaker s'ouvre après N échecs
- **GIVEN** un embedder externe qui retourne HTTP 5xx en boucle
- **WHEN** 5 appels consécutifs échouent dans une fenêtre de 30 s
- **THEN** le 6ème appel lève `CircuitOpenError` **immédiatement** (sans toucher au backend)
- **AND** `stats[:circuit_state]` est `:open`
- **AND** après 60 s, le circuit passe à `:half_open` et autorise un appel d'essai

#### Scenario: Provider local n'est pas wrappé (zéro réseau)
- **GIVEN** `RECONAUT_EMBEDDER_PROVIDER=local`
- **WHEN** `Embedder.build(env: ENV)` est appelé
- **THEN** l'objet retourné est `Reconaut::Embedder::Local` directement (pas wrappé dans `Resilient`)
- **AND** un test qui stubbe `Net::HTTP.start → boom` confirme qu'aucun appel réseau n'est tenté

### Requirement: Boot Validation of Embedder Configuration
Le boot Rails DOIT valider la configuration de l'embedder (variable `RECONAUT_EMBEDDER_PROVIDER` + variables spécifiques par provider) et DOIT échouer le boot avec un message clair listant la variable manquante si la config est invalide.

L'opérateur ne DOIT PAS découvrir une misconfiguration uniquement à la première requête `/agent/chat` — un container qui boot OK mais renvoie 500 sur la première requête est plus traître qu'un container qui crashloop avec un message clair.

#### Scenario: Boot fail-fast quand `ollama` sans URL
- **GIVEN** `RECONAUT_EMBEDDER_PROVIDER=ollama` et `RECONAUT_EMBEDDER_OLLAMA_URL` non défini
- **WHEN** `bin/rails server` démarre
- **THEN** le boot échoue avec exit code ≠ 0
- **AND** le message d'erreur contient `embedder-misconfigured` et nomme la variable manquante (`RECONAUT_EMBEDDER_OLLAMA_URL`)

#### Scenario: Boot OK avec provider local
- **GIVEN** aucune variable `RECONAUT_EMBEDDER_*` définie (défaut `local`)
- **WHEN** `bin/rails server` démarre
- **THEN** le boot réussit
- **AND** un log `[embedder] provider=local dim=384` apparaît au démarrage

### Requirement: Doctor Reports Embedder Health
La task `bundle exec rails reconaut:doctor` DOIT exposer un check `embedder_health` qui inclut le provider actif, sa dimension, l'état du circuit breaker et le compteur d'échecs accumulé.

#### Scenario: Doctor imprime l'état embedder
- **GIVEN** une instance avec `RECONAUT_EMBEDDER_PROVIDER=local`
- **WHEN** `bundle exec rails reconaut:doctor` est exécutée
- **THEN** la sortie JSON contient un check `{"name":"embedder_health","status":"info","details":{"provider":"local","dim":384,"circuit_state":"closed","failures_total":0}}`
