# Spec delta : agent-interface

## MODIFIED Requirements

### Requirement: Semantic Search over Indexed Assets
L'agent DOIT répondre aux requêtes en langage naturel via un **pipeline de retrieval hybride** combinant rappel vectoriel (via l'interface `Embedder` configurable par env, cf. exigences `Local Embedder by Default`) et expansion graphe via les templates paramétrés définis dans la capacité `graph-retrieval`. Le rappel vectoriel reste l'ancrage par défaut pour les requêtes sémantiques sur texte libre (bannières, extraits HTML, fingerprints). L'expansion graphe (1–3 sauts, lecture seule) ajoute le contexte structurel (clusters de certificats, voisinage AS, chaînes domaine→hôte, jointures CPE→Vulnerability). Chaque résultat DOIT citer son enregistrement de scan source pour que l'utilisateur vérifie la provenance.

#### Scenario: Utilisateur cherche les Modbus exposés en France
- **GIVEN** l'index contient des hôtes avec country=`FR` exposant un service tagué `modbus`
- **WHEN** un utilisateur authentifié soumet la requête « modbus exposés en France » via `POST /agent/chat`
- **THEN** l'agent renvoie les top-K résultats (K configurable, défaut 5)
- **AND** chaque hôte renvoyé a country=`FR` et au moins un service tagué `modbus`
- **AND** chaque résultat inclut un couple de citation `(host_id, scanned_at)` référençant l'enregistrement de scan source
- **AND** le temps de réponse end-to-end P95 sur le chemin chaud est < 2,5 s pour un ensemble de résultats ≤ 50 hôtes

#### Scenario: Requête structurelle déclenche l'expansion graphe
- **GIVEN** un utilisateur authentifié soumet « hôtes partageant le certificat sha256:abc... » via `POST /agent/chat`
- **WHEN** le pipeline traite la requête
- **THEN** le LLM sélectionne un template `graph-retrieval` paramétré par le hash de cert (pas de Cypher généré dynamiquement)
- **AND** la réponse contient les hôtes du cluster du certificat avec citations `(host_id, scanned_at)` issues du dernier scan connu
- **AND** la métrique `retrieval_path{path="graph"}` est incrémentée

#### Scenario: Requête mixte combine vectoriel et graphe
- **GIVEN** un utilisateur soumet « serveurs nginx vulnérables hébergés chez OVH »
- **WHEN** le pipeline traite la requête
- **THEN** le rappel vectoriel ancre les candidats sur la similarité de bannière `nginx`
- **AND** l'expansion graphe filtre par `IN_AS → AutonomousSystem(OVH)` et joint `MATCHES_CPE → AFFECTED_BY → Vulnerability`
- **AND** la réponse cite chaque hôte renvoyé via `(host_id, scanned_at)` et indique les CVE matchées

#### Scenario: Ensemble de résultats vide est explicite
- **WHEN** une requête donne zéro correspondance au-dessus du seuil de similarité ET zéro nœud graphe pertinent
- **THEN** l'agent renvoie un tableau `results` vide et un message textuel indiquant qu'aucun hôte n'a matché, plutôt que de fabriquer des résultats

### Requirement: RBAC-Scoped Conversation Context
L'agent DEVRA appliquer le contrôle d'accès par authentification et RBAC en amont du pipeline de retrieval. Reconaut étant tenant unique, aucun filtre `tenant_id` n'est appliqué dans les requêtes vectorielles ni dans les templates Cypher. L'autorisation d'appeler `/agent/chat` est gardée par le rôle minimum (`analyst` ou supérieur) ; un `viewer` est rejeté en 403 avant tout calcul.

#### Scenario: Viewer rejeté avant tout calcul
- **GIVEN** un utilisateur authentifié avec le rôle `viewer`
- **WHEN** l'utilisateur appelle `POST /agent/chat`
- **THEN** Rails rejette la requête avec HTTP 403 avant tout appel embedder ou Cypher
- **AND** aucun appel sortant ni Cypher n'est observé pendant le test

#### Scenario: Aucun paramètre tenant dans le pipeline
- **GIVEN** une revue automatisée du code du pipeline hybride
- **WHEN** un linter scanne les SQL/Cypher générés et les payloads d'embedder
- **THEN** aucun filtre `tenant_id` n'est présent ; aucun paramètre `tenant`, `caller_tenant` ou équivalent n'est lu ou injecté

## ADDED Requirements

### Requirement: Graceful Degradation When Graph Unavailable
Si la couche `graph-retrieval` est indisponible (extension AGE absente, timeout de template, erreur de configuration RLS), l'agent DOIT dégrader gracieusement vers le retrieval vectoriel pur et signaler la dégradation dans la réponse, plutôt que d'échouer totalement la requête utilisateur. L'agent NE DOIT JAMAIS fabriquer de relations graphe ni inférer un voisinage quand le graphe est indisponible.

#### Scenario: AGE indisponible pendant une requête structurelle
- **GIVEN** AGE renvoie `extension not loaded` ou un timeout de template
- **WHEN** un utilisateur soumet une requête structurelle (par ex. cluster de certificat)
- **THEN** le pipeline tente le rappel vectoriel pur sur la requête, retourne les résultats correspondants au mieux
- **AND** la réponse inclut un avertissement structuré `{ "warnings": ["graph_unavailable"] }` ; le client peut afficher un message à l'utilisateur
- **AND** la métrique `graph_unavailable_total` est incrémentée
- **AND** un log structuré niveau `warn` est émis avec la cause technique
