# Spec delta : architecture

## ADDED Requirements

### Requirement: Frontend Framework
Le frontend web de Reconaut DOIT être implémenté en Vue.js (3.x ou supérieur) avec la Composition API. Aucun autre framework UI (React, Svelte, Angular, Solid, etc.) NE DOIT être livré dans le périmètre v1. Le bundle de production servi aux utilisateurs ne contient que des artefacts issus de la chaîne de build Vue.

#### Scenario: Tentative d'introduire un composant React
- **GIVEN** une PR ajoute un fichier `.jsx` ou `.tsx` important `react`
- **WHEN** le pipeline CI s'exécute
- **THEN** un check de stack rejette la PR avec le message `frontend-stack-violation: only Vue.js components allowed`
- **AND** le job ne progresse pas vers le build du bundle

#### Scenario: Bundle de production servi aux utilisateurs
- **GIVEN** un build de production déployé en EU
- **WHEN** un client charge l'application web
- **THEN** les assets JavaScript servis sont exclusivement issus du build Vue (manifest Vite ou équivalent), sans runtime React/Angular/Svelte

### Requirement: Backend Application Runtime
Le backend applicatif de Reconaut (API tenant, agent conversationnel, facturation, journal d'audit, et serveur MCP) DOIT être implémenté en Ruby on Rails. Le serveur MCP HTTP+SSE DOIT s'exécuter à l'intérieur du même process Rails que le reste de l'API, partageant la pile de middlewares (auth, rate-limit, audit, observabilité). Aucun service backend séparé n'héberge le MCP en v1.

#### Scenario: Endpoint MCP partage l'auth de l'API tenant
- **GIVEN** le serveur Rails est démarré avec sa pile de middlewares standard
- **WHEN** un appel d'outil MCP arrive sur l'endpoint HTTP+SSE et un appel REST arrive sur l'API tenant
- **THEN** les deux requêtes traversent le même middleware d'authentification (clé API tenant) et le même middleware de journal d'audit
- **AND** une entrée d'audit produite par MCP utilise le même schéma de table que les entrées produites par l'API REST

#### Scenario: Aucun service MCP séparé déployé
- **GIVEN** l'environnement de production
- **WHEN** un opérateur liste les processus déployés
- **THEN** il n'existe pas de processus dédié au MCP distinct du process Rails ; le port HTTP+SSE MCP est servi par le même binaire Rails que les routes API

### Requirement: Scan Workers Runtime
Les workers de scan (énumération de sous-domaines, port scan, fingerprinting de protocole, capture de bannière, parsing TLS) DOIVENT être implémentés en Rust et exécutés comme binaires séparés du process Rails. Aucune logique de scan (ouverture de socket vers une cible, parsing de réponse réseau d'une cible) NE DOIT résider dans le code Rails ou dans une gem Ruby chargée par Rails.

#### Scenario: Crash d'un worker Rust n'affecte pas l'API
- **GIVEN** un worker Rust traite un job et panique sur une réponse malformée
- **WHEN** le process worker se termine
- **THEN** le process Rails continue de servir l'API et MCP sans interruption
- **AND** le job est remis en file selon la politique de retry du broker

#### Scenario: Le code Rails n'ouvre pas de socket vers une cible de scan
- **GIVEN** une revue automatisée du codebase Rails
- **WHEN** le linter de stack scanne les imports et les appels
- **THEN** aucun appel à `Socket.tcp`, `Net::HTTP`, `OpenSSL::SSL::SSLSocket` ou équivalent n'est fait avec une URL/adresse provenant d'un enregistrement `Host` de tenant
- **AND** seuls les appels sortants vers les services internes (broker, base, IdP, Mistral, Stripe) et le serveur d'audit sont autorisés

### Requirement: Rails ↔ Rust Communication via Job Queue
Rails et les workers Rust DOIVENT communiquer exclusivement via une file de jobs distribuée. Aucun appel synchrone Rails → Rust (HTTP, gRPC, RPC propriétaire) NE DOIT exister. Le contrat est un schéma de message versionné comportant au minimum un `schema_version` (entier monotone), une clé d'idempotence et la charge utile typée du job ou du résultat.

#### Scenario: Demande de scan se matérialise comme un message de file
- **GIVEN** un utilisateur appelle `POST /scans` ou un agent MCP appelle `request_scan`
- **WHEN** Rails accepte la demande
- **THEN** Rails publie exactement un message de job sur le broker avec un `schema_version`, une clé d'idempotence dérivée de la cible et du tenant, et le payload typé
- **AND** Rails renvoie immédiatement un `scan_id` corrélé sans attendre l'exécution du scan
- **AND** un test d'intégration vérifie que le message publié matche le schéma JSON déclaré

#### Scenario: Aucun client RPC synchrone Rust dans le code Rails
- **GIVEN** une revue automatisée du codebase Rails
- **WHEN** le linter de stack scanne les dépendances et imports
- **THEN** aucune gem cliente RPC vers les workers Rust n'est présente (pas de gRPC client vers `scanner-rpc`, pas de client HTTP avec base URL `scanner.*`)
- **AND** la seule sortance Rails vers le périmètre scan est la publication sur le broker de jobs

#### Scenario: Évolution de schéma préservant la compatibilité
- **GIVEN** la version `schema_version=1` est en production et un nouveau champ optionnel est introduit en `schema_version=2`
- **WHEN** un worker à jour reçoit un message v1 ou v2
- **THEN** le worker traite les deux versions sans erreur
- **AND** un worker non encore mis à jour reçoit un message v2 et le rejette explicitement (avec remise en file ou DLQ) plutôt que de silencieusement ignorer le nouveau champ

### Requirement: Horizontal Distribution of Scan Workers
Les workers Rust DOIVENT pouvoir être instanciés à `N>1` sur plusieurs machines et plusieurs régions EU sans coordination explicite entre instances — le broker assure la distribution. La consommation est au-moins-une-fois ; l'idempotence du traitement repose sur la clé d'idempotence du message portée par le contrat de job.

#### Scenario: Plusieurs workers consomment la même file
- **GIVEN** 5 workers Rust démarrés sur 5 hôtes distincts dans deux régions EU, abonnés à la même file
- **WHEN** 1000 jobs sont publiés en burst
- **THEN** chaque job est traité au moins une fois et au plus N fois (où N est borné par la politique de retry)
- **AND** aucun job ne reste non-traité après que la file s'est vidée
- **AND** un test charge mesure que la charge est répartie sur les 5 workers (variance de débit < 30 % autour de la moyenne)

#### Scenario: Idempotence portée par le job
- **GIVEN** un job avec clé d'idempotence `idem_key=K` est consommé deux fois (redelivery du broker)
- **WHEN** le worker traite chaque livraison
- **THEN** le résultat persisté en base ne contient qu'une seule occurrence pour `K` ; la seconde livraison est détectée et acquittée sans nouvelle écriture

### Requirement: EU Residency of the Job Broker
Le broker de jobs utilisé pour la communication Rails ↔ Rust DOIT être hébergé dans la liste blanche de régions EU/EEE définie par la spec `gdpr-compliance`. Tous les messages persistés (en transit ou en backlog) DOIVENT résider chez un fournisseur EU et ne JAMAIS transiter par un endpoint hors EU/EEE.

#### Scenario: Configuration du broker rejetée en région non-EU
- **GIVEN** la configuration de déploiement déclare un endpoint de broker dans `us-east-1`
- **WHEN** le pipeline IaC s'exécute (`terraform plan` ou équivalent)
- **THEN** le plan est rejeté avec le message `broker-region-not-allowed: us-east-1 not in EU whitelist`
- **AND** le déploiement n'avance pas

#### Scenario: Self-check au boot vérifie la région du broker
- **GIVEN** le process Rails démarre et se connecte au broker
- **WHEN** la routine `doctor` de boot s'exécute
- **THEN** elle interroge les métadonnées du broker (région annoncée par le fournisseur ou résolution DNS contre une liste blanche d'IPs EU) et logue la région
- **AND** si la région ne fait pas partie de la liste blanche EU, le process refuse de servir du trafic et sort en non-zero
