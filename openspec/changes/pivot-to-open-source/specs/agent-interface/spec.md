# Spec delta : agent-interface

## MODIFIED Requirements

### Requirement: Semantic Search over Indexed Assets
L'agent DOIT répondre aux requêtes en langage naturel en récupérant les hôtes et services pertinents via une couche d'embeddings exposée par l'**interface `Embedder`**, sur une représentation chunkée des métadonnées d'hôte, des bannières et des certificats. La plateforme livre au moins trois implémentations interchangeables — un embedder local self-hostable (défaut, exécuté in-process ou via un sidecar sans appel sortant), un client `mistral-embed` et un client OpenAI-compatible générique — et la sélection se fait au déploiement par configuration. Chaque résultat DOIT citer son enregistrement de scan source pour que l'utilisateur vérifie la provenance.

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
- **AND** le temps de réponse end-to-end P95 sur le chemin chaud est < 2,5 s pour un ensemble de résultats ≤ 50 hôtes (peut varier en fonction de la latence de l'embedder configuré ; valeur cible mesurée avec l'embedder local par défaut)

#### Scenario: Ensemble de résultats vide est explicite
- **WHEN** une requête donne zéro correspondance au-dessus du seuil de similarité
- **THEN** l'agent renvoie un tableau `results` vide et un message textuel indiquant qu'aucun hôte n'a matché, plutôt que de fabriquer des résultats

### Requirement: Tenant-Scoped Conversation Context (Multi-Tenant Mode)
L'agent DEVRA récupérer uniquement les données que l'utilisateur requérant est autorisé à voir. **En mode multi-tenant** (opt-in), la fuite cross-tenant DOIT être empêchée par construction : le filtre tenant DOIT être appliqué au niveau de la requête vers le vector store et, le cas échéant, au niveau des templates graphe — jamais comme filtre post-récupération. **En mode single-tenant** (défaut), un seul tenant implicite `default` existe et la propriété d'isolation est trivialement satisfaite ; la même surface de code (filtre poussé dans la requête) reste exercée pour éviter une régression à l'activation du mode multi-tenant.

#### Scenario: Mode multi-tenant — utilisateur du tenant A interroge l'agent
- **GIVEN** le mode multi-tenant est activé et les tenants A et B ont chacun des hôtes privés tagués sur mesure dans l'index
- **WHEN** un utilisateur authentifié comme tenant A soumet une requête quelconque
- **THEN** la récupération vectorielle est contrainte par `tenant_id IN ('A', 'public')` au niveau de la requête vers l'index
- **AND** un test d'intégration exécute ≥ 100 requêtes randomisées du tenant A et assure qu'aucun résultat ne référence un hôte privé du tenant B

#### Scenario: Mode single-tenant — chemin de filtre exercé
- **GIVEN** le mode single-tenant (défaut)
- **WHEN** un utilisateur soumet une requête
- **THEN** la requête vectorielle inclut toujours `WHERE tenant_id = 'default'` dans le SQL généré (la couche de filtre n'est pas court-circuitée)
- **AND** un test vérifie cette propriété en inspectant le SQL effectivement exécuté

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

## ADDED Requirements

### Requirement: Local Embedder by Default
La distribution livrée DOIT inclure un embedder local self-hostable activé par défaut, sans configuration et sans clé API requise. Aucun appel sortant **ne DOIT** être émis par le chemin d'embedding tant que l'opérateur n'active pas explicitement un provider externe. Le modèle concret utilisé par cet embedder local est différé (à choisir entre `bge-small`, `e5-small-v2`, `nomic-embed-text` ou équivalent au moment de l'implémentation), mais la propriété « zéro appel sortant » est non-négociable.

#### Scenario: Boot par défaut, embedding local actif
- **GIVEN** une image OCI freshly pulled, démarrée sans variable d'environnement `EMBEDDER_*`
- **WHEN** une requête utilisateur exerce le chemin d'embedding
- **THEN** un test d'audit réseau (vérifie les sockets sortants ouverts) ne voit aucune connexion vers un endpoint LLM
- **AND** la requête est servie avec succès et les vecteurs produits ont la dimension annoncée par la configuration de l'embedder local

#### Scenario: Activation explicite d'un provider externe
- **GIVEN** l'opérateur édite la config pour `embedder.provider=mistral` et fournit une clé
- **WHEN** l'instance redémarre
- **THEN** la couche d'embedding utilise désormais Mistral et un log `embedder=mistral, endpoint=<URL>` est émis au boot pour transparence
- **AND** sans cette édition explicite, le chemin local reste actif
