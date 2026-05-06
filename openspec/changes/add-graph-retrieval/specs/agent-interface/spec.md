# Spec delta : agent-interface

## MODIFIED Requirements

### Requirement: Semantic Search over Indexed Assets
L'agent DOIT répondre aux requêtes en langage naturel via un **pipeline de retrieval hybride** combinant rappel vectoriel `mistral-embed` (1024-dim, cohérent avec la spec existante) et expansion graphe via les templates paramétrés définis dans la capacité `graph-retrieval`. Le rappel vectoriel reste l'ancrage par défaut pour les requêtes sémantiques sur texte libre (bannières, extraits HTML, fingerprints). L'expansion graphe (1–3 sauts, lecture seule) ajoute le contexte structurel (clusters de certificats, voisinage AS, chaînes tenant→domaine→hôte, jointures CPE→Vulnerability). Les appels à l'API Mistral DOIVENT cibler le endpoint EU et être encadrés par un DPA Art. 28 (voir spec `gdpr-compliance`). Chaque résultat DOIT citer son enregistrement de scan source pour que l'utilisateur vérifie la provenance.

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

### Requirement: Tenant-Scoped Conversation Context
L'agent DEVRA récupérer uniquement les données que l'utilisateur requérant est autorisé à voir. La fuite cross-tenant DOIT être empêchée par construction sur les **deux chemins** du pipeline hybride : le filtre tenant DOIT être appliqué (a) au niveau de la requête vers le vector store, et (b) au niveau de la clause Cypher de chaque template graphe — jamais comme filtre post-récupération.

#### Scenario: Utilisateur du tenant A interroge l'agent
- **GIVEN** les tenants A et B ont chacun des hôtes privés tagués sur mesure dans l'index ET dans le graphe
- **WHEN** un utilisateur authentifié comme tenant A soumet une requête quelconque
- **THEN** la requête est rejetée avec HTTP 403 avant tout calcul (auth + RBAC) ou exécutée sans filtre tenant si l'utilisateur a le rôle requis (modèle tenant unique)
- **AND** aucun paramètre `tenant_id` n'est lu ni produit par le pipeline
- **AND** un test d'intégration exécute ≥ 100 requêtes randomisées du tenant A (mix sémantique et structurel) et assure qu'aucun résultat ne référence un hôte privé du tenant B

#### Scenario: Jeu de données public reste interrogeable
- **GIVEN** des enregistrements de scan ingérés sous le scope tenant `public` (présents à la fois en index vectoriel et en graphe)
- **WHEN** un utilisateur du tenant A interroge
- **THEN** les enregistrements `public` correspondants sont renvoyés aux côtés des enregistrements privés du tenant A, classés par similarité ou par pertinence graphe selon le chemin

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
