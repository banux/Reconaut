# Spec delta : agent-interface

## ADDED Requirements

### Requirement: Semantic Search over Indexed Assets
L'agent DOIT répondre aux requêtes en langage naturel en récupérant les hôtes et services pertinents via les embeddings `multilingual-e5-small` (384-dim) sur une représentation chunkée des métadonnées d'hôte, des bannières et des certificats. Chaque résultat DOIT citer son enregistrement de scan source pour que l'utilisateur vérifie la provenance.

#### Scenario: Utilisateur cherche les Modbus exposés en France
- **GIVEN** l'index contient des hôtes avec country=`FR` exposant un service tagué `modbus`
- **WHEN** un utilisateur authentifié soumet la requête « modbus exposés en France » via `POST /agent/chat`
- **THEN** l'agent renvoie les top-K résultats (K configurable, défaut 5 depuis `config.json`)
- **AND** chaque hôte renvoyé a country=`FR` et au moins un service tagué `modbus`
- **AND** chaque résultat inclut un couple de citation `(host_id, scanned_at)` référençant l'enregistrement de scan source
- **AND** le temps de réponse end-to-end P95 sur le chemin chaud est < 2,5 s pour un ensemble de résultats ≤ 50 hôtes

#### Scenario: Ensemble de résultats vide est explicite
- **WHEN** une requête donne zéro correspondance au-dessus du seuil de similarité
- **THEN** l'agent renvoie un tableau `results` vide et un message textuel indiquant qu'aucun hôte n'a matché, plutôt que de fabriquer des résultats

### Requirement: Tenant-Scoped Conversation Context
L'agent DEVRA récupérer uniquement les données que l'utilisateur requérant est autorisé à voir. La fuite cross-tenant DOIT être empêchée par construction : le filtre tenant DOIT être appliqué au niveau de la requête vers le vector store, pas comme filtre post-récupération.

#### Scenario: Utilisateur du tenant A interroge l'agent
- **GIVEN** les tenants A et B ont chacun des hôtes privés tagués sur mesure dans l'index
- **WHEN** un utilisateur authentifié comme tenant A soumet une requête quelconque
- **THEN** la récupération vectorielle est contrainte par `tenant_id IN ('A', 'public')` au niveau de la requête vers l'index
- **AND** un test d'intégration exécute ≥ 100 requêtes randomisées du tenant A et assure qu'aucun résultat ne référence un hôte privé du tenant B

#### Scenario: Jeu de données public reste interrogeable
- **GIVEN** des enregistrements de scan ingérés sous le scope tenant `public`
- **WHEN** un utilisateur du tenant A interroge
- **THEN** les enregistrements `public` correspondants sont renvoyés aux côtés des enregistrements privés du tenant A, classés par similarité
