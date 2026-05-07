# Spec delta : agent-interface

## ADDED Requirements

### Requirement: Semantic Search over Indexed Assets
L'agent DOIT répondre aux requêtes en langage naturel en récupérant les hôtes et services pertinents via une couche d'embeddings exposée par l'**interface `Embedder`**, sur une représentation chunkée des métadonnées d'hôte, des bannières et des certificats. La plateforme livre au moins **quatre implémentations** interchangeables : (a) un embedder **local in-process** (défaut, sans appel sortant), (b) un client **Ollama** (sidecar local — endpoint REST `http(s)://...:11434` typiquement sur `localhost` ou réseau privé), (c) un client **`mistral-embed`** (API EU), et (d) un client **OpenAI-compatible** générique. La sélection se fait par variable d'environnement. Chaque résultat DOIT citer son enregistrement de scan source pour que l'utilisateur vérifie la provenance.

#### Scenario: Configuration par défaut tourne sans appel sortant
- **GIVEN** une instance bootée sans configuration explicite d'`embedder` (défaut `local`)
- **WHEN** un utilisateur authentifié soumet une requête à l'agent
- **THEN** la requête est servie avec succès en utilisant l'embedder local
- **AND** un test d'audit réseau confirme qu'aucune connexion sortante vers un endpoint LLM externe n'a été ouverte pendant la requête

#### Scenario: Utilisateur cherche les Modbus exposés en France
- **GIVEN** l'index contient des hôtes avec country=`FR` exposant un service tagué `modbus`
- **WHEN** un utilisateur authentifié soumet la requête « modbus exposés en France » via `POST /agent/chat`
- **THEN** l'agent renvoie les top-K résultats (K configurable, défaut 5)
- **AND** chaque hôte renvoyé a country=`FR` et au moins un service tagué `modbus`
- **AND** chaque résultat inclut un couple de citation `(host_id, scanned_at)` référençant l'enregistrement de scan source
- **AND** le temps de réponse end-to-end P95 sur le chemin chaud est < 2,5 s pour un ensemble de résultats ≤ 50 hôtes (valeur cible mesurée avec l'embedder local par défaut ; peut varier avec un embedder externe configuré)

#### Scenario: Ensemble de résultats vide est explicite
- **WHEN** une requête donne zéro correspondance au-dessus du seuil de similarité
- **THEN** l'agent renvoie un tableau `results` vide et un message textuel indiquant qu'aucun hôte n'a matché, plutôt que de fabriquer des résultats

### Requirement: Local Embedder by Default, Configured by Environment Variables
La distribution livrée DOIT inclure un embedder local in-process activé par défaut, sans configuration et sans clé API requise. La sélection du provider DOIT se faire exclusivement par variables d'environnement standard (12-factor) — au minimum `RECONAUT_EMBEDDER_PROVIDER` (valeurs : `local` | `ollama` | `mistral` | `openai-compatible`, défaut `local`) et les variables spécifiques au provider sélectionné (`RECONAUT_EMBEDDER_LOCAL_MODEL`, `RECONAUT_EMBEDDER_OLLAMA_URL`, `RECONAUT_EMBEDDER_OLLAMA_MODEL`, `RECONAUT_EMBEDDER_MISTRAL_API_KEY`, `RECONAUT_EMBEDDER_OPENAI_BASE_URL` et `RECONAUT_EMBEDDER_OPENAI_API_KEY`). Aucun appel sortant **ne DOIT** être émis par le chemin d'embedding tant que l'opérateur n'active pas explicitement un provider non-`local`. Ollama, par défaut sur `localhost`, est considéré comme local-friendly mais reste un appel réseau (sortant vers `localhost` ou un réseau privé) — il NE DOIT PAS être actif tant que l'opérateur ne l'a pas explicitement sélectionné. Le modèle local par défaut concret est différé (à choisir entre `bge-small`, `e5-small-v2`, `nomic-embed-text` ou équivalent au moment de l'implémentation).

#### Scenario: Boot par défaut, embedding local actif
- **GIVEN** une image OCI fraîchement pullée, démarrée sans variable `RECONAUT_EMBEDDER_*`
- **WHEN** une requête utilisateur exerce le chemin d'embedding
- **THEN** un test d'audit réseau (vérifie les sockets sortants ouverts) ne voit aucune connexion vers un endpoint LLM
- **AND** la requête est servie avec succès et les vecteurs produits ont la dimension annoncée par la configuration de l'embedder local

#### Scenario: Activation explicite d'un provider externe par variable d'environnement
- **GIVEN** l'opérateur définit `RECONAUT_EMBEDDER_PROVIDER=mistral` et `RECONAUT_EMBEDDER_MISTRAL_API_KEY=<clé>` dans son environnement de déploiement
- **WHEN** l'instance redémarre
- **THEN** la couche d'embedding utilise désormais Mistral et un log `embedder=mistral, endpoint=<URL>` est émis au boot pour transparence
- **AND** sans cette définition explicite, le chemin local reste actif

#### Scenario: Modèle local choisi par variable d'environnement
- **GIVEN** l'opérateur définit `RECONAUT_EMBEDDER_LOCAL_MODEL=bge-small-en-v1.5`
- **WHEN** l'instance démarre
- **THEN** l'embedder local charge ce modèle et logue `embedder=local, model=bge-small-en-v1.5` au boot
- **AND** sans cette variable, un modèle par défaut livré dans l'image est utilisé

#### Scenario: Activation d'Ollama en sidecar local
- **GIVEN** l'opérateur définit `RECONAUT_EMBEDDER_PROVIDER=ollama`, `RECONAUT_EMBEDDER_OLLAMA_URL=http://ollama:11434`, `RECONAUT_EMBEDDER_OLLAMA_MODEL=nomic-embed-text` et démarre un container `ollama/ollama` sur le même réseau
- **WHEN** l'instance redémarre
- **THEN** la couche d'embedding appelle `POST http://ollama:11434/api/embeddings` (ou `/v1/embeddings` selon le mode Ollama) avec le modèle configuré
- **AND** un log `embedder=ollama, url=http://ollama:11434, model=nomic-embed-text` est émis au boot
- **AND** aucune connexion sortante vers internet public n'est observée si Ollama tourne sur le même réseau privé

### Requirement: External Embedder Resilience (Conditional)
**Quand l'opérateur configure un embedder externe** (Mistral, OpenAI-compatible ou autre), l'appel d'embedding DOIT être borné par un timeout par requête, protégé par un circuit breaker et observable via des métriques. En cas d'indisponibilité du fournisseur, l'agent DOIT échouer explicitement plutôt que de fabriquer des résultats. L'interface `Embedder` rend la substitution transparente pour le reste du code applicatif. Cette exigence ne s'applique pas à l'embedder local par défaut, qui tourne in-process et n'a pas de mode « réseau indisponible ».

#### Scenario: Provider externe indisponible
- **GIVEN** l'opérateur a configuré `embedder.provider=mistral` et l'API renvoie 5xx ou time out
- **WHEN** un utilisateur soumet une requête à l'agent
- **THEN** l'agent renvoie HTTP 503 avec body `{ "error": "embedding_provider_unavailable", "provider": "mistral" }` ; il ne renvoie ni résultats fabriqués ni résultats issus d'un cache au-delà de l'index sémantique existant
- **AND** la métrique `embedding_provider_failures_total{provider="mistral"}` incrémente

#### Scenario: Timeout par requête
- **GIVEN** un embedder externe configuré
- **WHEN** un appel dépasse le timeout configuré (défaut 2,5 s)
- **THEN** la connexion est annulée et l'erreur est remontée comme un échec d'embedding ; aucune requête « zombie » ne continue en arrière-plan
- **AND** la métrique `embedding_provider_latency_seconds{provider=...}` enregistre l'observation tronquée au timeout

#### Scenario: Circuit breaker ouvert
- **GIVEN** N échecs consécutifs sur la fenêtre configurée (défaut N=5 sur 30 s)
- **WHEN** une nouvelle requête tente un appel
- **THEN** le circuit breaker est ouvert et l'appel est rejeté immédiatement sans tentative réseau pendant la durée configurée (défaut 60 s)
- **AND** un log structuré niveau `warn` est émis avec `circuit=open`, `provider=<nom>`
