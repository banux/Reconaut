# Spec delta : graph-retrieval

## ADDED Requirements

### Requirement: Asset Graph Projection
La plateforme DOIT matérialiser un graphe d'actifs dérivé déterministiquement des données de scan structurées, dans Apache AGE sur le cluster Postgres existant. Les labels de nœuds DOIVENT inclure au minimum : `Tenant`, `Domain`, `Host`, `Service`, `Certificate`, `AutonomousSystem`, `IPRange`, `CPE`, `Vulnerability`. Les arêtes DOIVENT couvrir au minimum : `MONITORS` (Tenant→Domain), `RESOLVES_TO` (Domain→Host), `EXPOSES` (Host→Service), `PRESENTS` (Host→Certificate), `IN_AS` (Host→AutonomousSystem), `IN_RANGE` (Host→IPRange), `MATCHES_CPE` (Service→CPE), `AFFECTED_BY` (CPE→Vulnerability). Aucune extraction LLM NE DOIT être utilisée pour construire le graphe.

#### Scenario: Ingestion d'un scan projette les nœuds et arêtes
- **GIVEN** un résultat de scan ingéré contenant un nouvel hôte `H1` avec un service Modbus `S1` et un certificat `C1` partagé avec un hôte existant `H2`
- **WHEN** le pipeline d'ingestion termine la transaction
- **THEN** le graphe contient les nœuds `Host(H1)`, `Service(S1)`, `Certificate(C1)` et les arêtes `EXPOSES(H1→S1)`, `PRESENTS(H1→C1)`, `PRESENTS(H2→C1)`
- **AND** aucun appel à l'API Mistral n'a été effectué pendant l'ingestion (vérifié par mock outbound dans le test)

#### Scenario: Aucune extraction LLM dans le chemin d'index
- **GIVEN** une revue automatisée du code d'ingestion
- **WHEN** le linter scanne les imports et les appels sortants du code de projection graphe
- **THEN** aucun appel à `Embedder`, `MistralClient` ou tout autre client LLM n'est observé dans le chemin de construction du graphe

### Requirement: Bounded Graph Staleness
La projection graphe DOIT refléter l'état des données de scan ingérées avec une staleness bornée. Cible : `p95(graph_lag_seconds) < 60 s`, `p99 < 300 s` mesurée entre l'horodatage d'ingestion d'un scan et la disponibilité de ses nœuds/arêtes en lecture par les templates.

#### Scenario: Mesure du retard de projection
- **GIVEN** un test d'intégration qui ingère 1000 scans synthétiques sur 60 secondes
- **WHEN** chaque scan est suivi d'une requête de template qui doit voir l'arête correspondante
- **THEN** la métrique `graph_lag_seconds` p95 reste sous 60 s sur toute la fenêtre
- **AND** la métrique est exposée comme histogramme Prometheus

### Requirement: Access Control via Authentication and RBAC
Reconaut étant tenant unique (cf. spec `platform`), l'accès aux templates de retrieval graphe DOIT être contrôlé par l'authentification et le RBAC standard, pas par un filtre `tenant_id` dans les clauses Cypher. Les templates DOIVENT exiger un rôle minimum (`analyst` au minimum pour `/agent/chat`, `viewer` interdit) appliqué côté Rails avant tout appel Cypher. Aucun paramètre `tenant_id` n'est attendu dans les templates ; les nœuds graphe n'ont pas de propriété `tenant_id`.

#### Scenario: Viewer ne peut pas exécuter de template graphe
- **GIVEN** un utilisateur avec le rôle `viewer`
- **WHEN** une requête arrive à un endpoint qui exercerait un template graphe (par ex. `/agent/chat` avec une requête structurelle)
- **THEN** Rails rejette la requête avec HTTP 403 avant tout appel Cypher
- **AND** une ligne d'audit `status=unauthorized` est écrite

#### Scenario: Aucun paramètre tenant_id dans les templates
- **GIVEN** une revue automatisée du registry de templates
- **WHEN** un test inspecte la signature de chaque template enregistré
- **THEN** aucune signature ne contient de paramètre `tenant_id`, `tenant`, `caller_tenant` ou équivalent
- **AND** aucun Cypher de template ne contient de clause `WHERE n.tenant_id = $tid`

### Requirement: Parameterized Read-Only Query Templates
Le code applicatif DOIT exposer un catalogue de templates Cypher paramétrés. Chaque template porte un `template_id` stable, une signature de paramètres typée et une clause Cypher fixe. Le LLM ne génère JAMAIS de Cypher : il sélectionne un `template_id` et fournit des paramètres typés. Les templates DOIVENT être en lecture seule — aucun template ne peut contenir `CREATE`, `MERGE`, `SET`, `DELETE`, `DETACH`, `REMOVE` ou toute autre clause mutante.

#### Scenario: Tentative d'enregistrer un template mutant
- **GIVEN** un développeur soumet un template contenant `DETACH DELETE n`
- **WHEN** la suite de tests `templates_lint` s'exécute en CI
- **THEN** le test échoue avec le message `template-not-readonly: forbidden clause DETACH DELETE in <template_id>`
- **AND** la PR ne peut être fusionnée

#### Scenario: Rôle Postgres restreint à la lecture
- **GIVEN** le rôle Postgres utilisé pour exécuter les templates
- **WHEN** une requête tente une mutation graphe (par construction de test)
- **THEN** Postgres rejette avec `permission denied` ; le rôle n'a pas `INSERT`/`UPDATE`/`DELETE` sur les tables AGE de labels et arêtes

#### Scenario: Sélection de template hors catalogue rejetée
- **GIVEN** le LLM retourne un `template_id` inconnu
- **WHEN** le routeur de templates tente la résolution
- **THEN** la requête est refusée avec `unknown_template` et journalisée ; aucune exécution Cypher n'a lieu

### Requirement: Hybrid Retrieval Pipeline
L'agent DOIT exécuter un pipeline de retrieval hybride composant rappel vectoriel et expansion graphe. Étapes minimales : (1) le LLM décompose la requête en partie sémantique (mots-clés) et partie structurelle (entités nommées, relations désirées) ; (2) ancrage vectoriel sur la partie sémantique → ensemble candidat de nœuds (Host, Service) ; (3) expansion graphe via templates paramétrés bornés à 1–3 sauts → sous-graphe contextuel ; (4) synthèse LLM avec citations sur chaque nœud visité.

#### Scenario: Requête structurelle déclenche le chemin graphe
- **GIVEN** un utilisateur soumet « hôtes partageant le cert sha256:abc... »
- **WHEN** le pipeline traite la requête
- **THEN** le LLM sélectionne le template `cert_cluster` avec `cert_sha256="abc..."`
- **AND** la réponse cite chaque hôte du cluster avec son couple `(host_id, scanned_at)` issu du dernier scan connu
- **AND** la métrique `retrieval_path{path="graph"}` est incrémentée

#### Scenario: Requête sémantique pure conserve le chemin vectoriel
- **GIVEN** un utilisateur soumet « serveurs nginx 1.18 vulnérables »
- **WHEN** le pipeline traite la requête
- **THEN** le rappel vectoriel sur `mistral-embed` retourne des candidats par similarité de bannière
- **AND** la métrique `retrieval_path{path="vector"}` est incrémentée
- **AND** le chemin graphe peut additionnellement enrichir le contexte (CPE→Vulnerability) sans changer l'ensemble candidat

#### Scenario: Profondeur d'expansion bornée
- **GIVEN** un template avec un paramètre `depth` exposé
- **WHEN** un appelant fournit `depth=10`
- **THEN** le validateur de paramètres rejette la valeur avec `depth-out-of-range: max=3`
- **AND** aucune exécution Cypher n'a lieu

### Requirement: Graceful Degradation When Graph Unavailable
Si AGE est indisponible (extension absente, requête en timeout, RLS rejette par erreur de configuration), le pipeline hybride DOIT dégrader gracieusement vers le retrieval vectoriel pur et le signaler dans la réponse. Le pipeline NE DOIT JAMAIS fabriquer de relations graphe quand le graphe est down.

#### Scenario: Indisponibilité AGE pendant une requête structurelle
- **GIVEN** AGE renvoie `extension not loaded` (cas pathologique)
- **WHEN** un utilisateur soumet une requête structurelle
- **THEN** le pipeline tente le rappel vectoriel pur, retourne les résultats correspondants
- **AND** la réponse inclut un avertissement structuré `{ "graph_unavailable": true }` plutôt qu'un échec total
- **AND** la métrique `graph_unavailable_total` est incrémentée
- **AND** un log structuré niveau `warn` est émis avec la cause

#### Scenario: Timeout de template
- **GIVEN** un template dépasse le timeout configuré (défaut 1,5 s)
- **WHEN** la requête est annulée
- **THEN** la connexion Postgres est libérée (pas de requête zombie), un fallback vectoriel est tenté, la métrique `graph_template_timeout_total{template_id=...}` incrémente

### Requirement: Graph Query Audit
Chaque exécution de template DOIT produire une entrée d'audit append-only contenant `template_id`, paramètres normalisés, `key_id` ou `user_id` du caller, durée d'exécution en ms, nombre de nœuds touchés, et statut (`success` / `timeout` / `unauthorized` / `unknown_template`). Le journal réutilise le même schéma de table que le journal d'audit défini dans `gdpr-compliance`.

#### Scenario: Trace d'audit pour exécution réussie
- **GIVEN** un utilisateur du tenant A déclenche le template `cert_cluster`
- **WHEN** l'exécution termine avec succès en 80 ms en touchant 12 nœuds
- **THEN** une ligne d'audit est écrite en moins de 1 s contenant `template_id="cert_cluster"`, `user_id` du caller, `duration_ms=80`, `nodes_touched=12`, `status="success"`
- **AND** un test d'intégration vérifie la présence de la ligne via `SELECT` sur la table d'audit

#### Scenario: Audit du rejet hors catalogue
- **GIVEN** un appel avec `template_id` inconnu
- **THEN** une ligne d'audit avec `status="unknown_template"` est écrite et la requête est rejetée

### Requirement: Erasure Coherence
La suppression DSAR d'un tenant DOIT retirer ses nœuds et arêtes de la projection graphe **dans la même transaction Postgres** que la suppression des lignes scalaires correspondantes. Aucun nœud ne DOIT survivre à la suppression de son tenant. Cette exigence est cohérente avec le workflow DSAR multi-région défini dans `gdpr-compliance`.

#### Scenario: Effacement d'un tenant retire les nœuds graphe
- **GIVEN** le tenant A possède 50 hôtes, 200 services et 30 certificats projetés en nœuds graphe
- **WHEN** un effacement DSAR pour le tenant A est exécuté
- **THEN** dans la même transaction, les lignes scalaires et les nœuds/arêtes AGE correspondants sont supprimés ; la transaction est atomique (commit ou rollback global)
- **AND** une vérification post-suppression dans **chaque région EU active** ne renvoie aucun nœud rattaché au tenant A
- **AND** une tombstone hashée est écrite dans le journal d'audit (cohérent avec `gdpr-compliance`)

### Requirement: EU Residency of the Graph Tier
Le graphe matérialisé DOIT résider intégralement sur le cluster Postgres EU déjà spécifié par `gdpr-compliance`. Aucune copie, export ou index secondaire du graphe NE DOIT vivre hors EU/EEE. La réplication multi-actif EU passe par le WAL Postgres ; aucun pipeline de réplication propre au graphe n'est introduit.

#### Scenario: Self-check au boot vérifie la coïncidence des régions
- **WHEN** le process Rails démarre et exécute la routine `doctor`
- **THEN** la routine confirme que l'extension AGE est chargée sur la même instance Postgres que les tables OLTP, et que la région de l'instance fait partie de la liste blanche EU
- **AND** si AGE est chargée sur une instance distincte hors-EU, le process refuse de servir du trafic et sort en non-zero
