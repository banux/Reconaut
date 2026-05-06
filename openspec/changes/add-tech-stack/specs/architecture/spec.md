# Spec delta : architecture

## ADDED Requirements

### Requirement: Frontend Framework
Le frontend web de Reconaut DOIT être implémenté en **Vue 3** (Composition API) avec **Vite** comme bundler. Aucun autre framework UI (React, Svelte, Angular, Solid, etc.) NE DOIT être livré dans le périmètre v1, et **pas de Nuxt** non plus en v1. Le bundle de production servi aux utilisateurs ne contient que des artefacts issus de la chaîne de build Vite + Vue.

#### Scenario: Tentative d'introduire un composant React
- **GIVEN** une PR ajoute un fichier `.jsx` ou `.tsx` important `react`
- **WHEN** le pipeline CI s'exécute
- **THEN** un check de stack rejette la PR avec le message `frontend-stack-violation: only Vue 3 components allowed`
- **AND** le job ne progresse pas vers le build du bundle

#### Scenario: Bundle de production servi aux utilisateurs
- **WHEN** un client charge l'application web
- **THEN** les assets JavaScript servis sont exclusivement issus du build Vite + Vue 3 (manifest Vite), sans runtime React/Angular/Svelte/Nuxt

### Requirement: Backend Application Runtime
Le backend applicatif de Reconaut (API, agent conversationnel, journal d'audit, et serveur MCP) DOIT être implémenté en **Ruby on Rails 8** (monolithe). Le serveur MCP HTTP+SSE DOIT s'exécuter à l'intérieur du même process Rails que le reste de l'API, partageant la pile de middlewares (auth, rate-limit, audit, observabilité). Aucun service backend séparé n'héberge le MCP en v1.

#### Scenario: Endpoint MCP partage l'auth de l'API
- **GIVEN** le serveur Rails est démarré avec sa pile de middlewares standard
- **WHEN** un appel d'outil MCP arrive sur l'endpoint HTTP+SSE et un appel REST arrive sur l'API
- **THEN** les deux requêtes traversent le même middleware d'authentification (clé API ou session OIDC) et le même middleware de journal d'audit
- **AND** une entrée d'audit produite par MCP utilise le même schéma de table que les entrées produites par l'API REST

#### Scenario: Aucun service MCP séparé déployé
- **GIVEN** l'environnement de production
- **WHEN** un opérateur liste les processus déployés
- **THEN** il n'existe pas de processus dédié au MCP distinct du process Rails ; le port HTTP+SSE MCP est servi par le même binaire Rails que les routes API

### Requirement: Scan Workers Runtime
Les workers de scan (énumération de sous-domaines, port scan, fingerprinting de protocole, capture de bannière, parsing TLS) DOIVENT être implémentés en **Go** (Golang) et exécutés comme binaires statiques séparés du process Rails. Aucune logique de scan (ouverture de socket vers une cible, parsing de réponse réseau d'une cible) NE DOIT résider dans le code Rails ou dans une gem Ruby chargée par Rails.

#### Scenario: Crash d'un worker Go n'affecte pas l'API
- **GIVEN** un worker Go traite un job et panique sur une réponse malformée
- **WHEN** le process worker se termine
- **THEN** le process Rails continue de servir l'API et MCP sans interruption
- **AND** le job est remis en file selon la politique de retry de GoodJob

#### Scenario: Le code Rails n'ouvre pas de socket vers une cible de scan
- **GIVEN** une revue automatisée du codebase Rails
- **WHEN** le linter de stack scanne les imports et les appels
- **THEN** aucun appel à `Socket.tcp`, `Net::HTTP`, `OpenSSL::SSL::SSLSocket` ou équivalent n'est fait avec une URL/adresse provenant d'un enregistrement `Host`
- **AND** seuls les appels sortants vers les services internes (Postgres, IdP OIDC si configuré, embedder externe si configuré) et le serveur d'audit sont autorisés

### Requirement: Rails ↔ Go Communication via GoodJob
Rails et les workers Go DOIVENT communiquer exclusivement via la **file de jobs GoodJob** (adapter ActiveJob backé par Postgres, table `good_jobs`). Aucun appel synchrone Rails → Go (HTTP, gRPC, RPC propriétaire) NE DOIT exister. Aucun broker externe (Redis, RabbitMQ, NATS, Kafka, etc.) NE DOIT être introduit dans la stack v1. Les workers Go consomment la table `good_jobs` directement via `SELECT ... FOR UPDATE SKIP LOCKED` (ou une bibliothèque Go qui implémente ce pattern compatible avec le schéma GoodJob). Le contrat est un schéma de message versionné comportant au minimum un `schema_version` (entier monotone), une clé d'idempotence et la charge utile typée du job ou du résultat.

#### Scenario: Demande de scan se matérialise comme un job GoodJob
- **GIVEN** un utilisateur appelle `POST /scans` ou un agent MCP appelle `request_scan`
- **WHEN** Rails accepte la demande
- **THEN** Rails enqueue exactement un job GoodJob avec un `schema_version`, une clé d'idempotence dérivée de la cible, et le payload typé
- **AND** Rails renvoie immédiatement un `scan_id` corrélé sans attendre l'exécution du scan
- **AND** un test d'intégration vérifie que le job persisté en table `good_jobs` (colonne `serialized_params`) matche le schéma JSON déclaré

#### Scenario: Aucun broker externe dans le déploiement
- **GIVEN** une instance Reconaut déployée
- **WHEN** un opérateur liste les services réseau
- **THEN** il n'existe pas de Redis, RabbitMQ, NATS ou Kafka exposé ; la seule infrastructure de file est le cluster Postgres déjà présent

#### Scenario: Aucun client RPC synchrone Go dans le code Rails
- **GIVEN** une revue automatisée du codebase Rails
- **WHEN** le linter de stack scanne les dépendances et imports
- **THEN** aucune gem cliente RPC vers les workers Go n'est présente (pas de gRPC client vers `scanner-rpc`, pas de client HTTP avec base URL `scanner.*`)
- **AND** la seule sortance Rails vers le périmètre scan est l'enqueue dans GoodJob

#### Scenario: Évolution de schéma préservant la compatibilité
- **GIVEN** la version `schema_version=1` est en production et un nouveau champ optionnel est introduit en `schema_version=2`
- **WHEN** un worker à jour reçoit un message v1 ou v2
- **THEN** le worker traite les deux versions sans erreur
- **AND** un worker non encore mis à jour reçoit un message v2 et le rejette explicitement (avec remise en file ou DLQ) plutôt que de silencieusement ignorer le nouveau champ

### Requirement: Horizontal Distribution of Scan Workers
Les workers Go DOIVENT pouvoir être instanciés à `N>1` sur plusieurs machines sans coordination explicite entre instances — le verrou ligne Postgres (`FOR UPDATE SKIP LOCKED`) garantit qu'un job est traité par un seul worker à la fois. La consommation est au-moins-une-fois ; l'idempotence du traitement repose sur la clé d'idempotence du message portée par le contrat de job.

#### Scenario: Plusieurs workers consomment la même file
- **GIVEN** 5 workers Go démarrés sur 5 hôtes distincts, tous connectés au même cluster Postgres
- **WHEN** 1000 jobs sont enqueued en burst
- **THEN** chaque job est traité au moins une fois et au plus N fois (où N est borné par la politique de retry GoodJob)
- **AND** aucun job ne reste non-traité après que la file s'est vidée
- **AND** un test charge mesure que la charge est répartie sur les 5 workers (variance de débit < 30 % autour de la moyenne)

#### Scenario: Idempotence portée par le job
- **GIVEN** un job avec clé d'idempotence `idem_key=K` est consommé deux fois (redelivery sur retry)
- **WHEN** le worker traite chaque livraison
- **THEN** le résultat persisté en base ne contient qu'une seule occurrence pour `K` ; la seconde livraison est détectée et acquittée sans nouvelle écriture

### Requirement: Single-Tenant Data Model
Reconaut est livré en mode **tenant unique** en v1. Le modèle de données NE COMPORTE PAS de notion de tenant : pas de colonne `tenant_id`, pas de RLS par tenant, pas d'UI de gestion de tenants. Une instance = un opérateur = un périmètre d'actifs. Un MSSP qui veut servir N clients DOIT déployer N instances Reconaut indépendantes.

#### Scenario: Schéma DB sans colonne tenant_id
- **GIVEN** le schéma Postgres de production après les migrations
- **WHEN** le linter de schéma s'exécute
- **THEN** aucune table métier (`hosts`, `services`, `certificates`, `scopes`, `scans`, `audit_log`, etc.) ne contient de colonne `tenant_id` ou équivalent

#### Scenario: API rejette tout paramètre de tenant
- **GIVEN** une instance déployée
- **WHEN** un client envoie une requête avec un paramètre `tenant_id` ou un header `X-Tenant`
- **THEN** l'API renvoie HTTP 400 `{ "error": "tenant_param_unsupported" }` (le mode multi-tenant n'existe pas en v1)
