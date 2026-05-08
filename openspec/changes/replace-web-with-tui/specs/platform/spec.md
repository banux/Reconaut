# Spec delta : platform

## MODIFIED Requirements

### Requirement: Authentication and RBAC
L'authentification DOIT être **local-first** : tout déploiement de Reconaut DOIT supporter l'authentification locale (utilisateur/mot de passe Argon2id + clés API personnelles hashées) **sans dépendance externe**. La voie locale DOIT rester disponible et fonctionnelle indéfiniment, même si un IdP externe est configuré. **OIDC** (Keycloak, Authentik, Dex, etc.) PEUT être activé en parallèle par configuration ; les deux mécanismes coexistent. L'instance NE DOIT JAMAIS exiger un IdP externe pour démarrer ou pour permettre la connexion d'un opérateur.

Le canal d'accès opérateur de référence est le **binaire TUI `reconautctl`** (cf. spec `architecture` : Requirement TUI Operator Surface). Le binaire échange les credentials contre une clé API personnelle côté Rails et utilise cette clé pour les appels suivants. Aucun navigateur web n'est requis pour le bootstrap, le login ou l'usage quotidien.

Les rôles `owner`, `admin`, `analyst`, `viewer` et `mcp_client` DOIVENT être imposés côté serveur sur chaque endpoint et chaque outil MCP, indépendamment du mécanisme d'authentification (clé API issue de TUI, session OIDC, ou clé API MCP).

#### Scenario: Bootstrap initial sans IdP externe et sans navigateur
- **GIVEN** une instance fraîchement déployée, sans configuration OIDC
- **WHEN** l'opérateur initial exécute `rails reconaut:bootstrap_owner` (ou équivalent CLI) puis `reconautctl login`
- **THEN** un compte `owner` local est créé avec le mot de passe défini à l'enrôlement
- **AND** `reconautctl login` échange ces credentials contre une clé API personnelle stockée sous `$XDG_CONFIG_HOME/reconaut/credentials`
- **AND** aucune connexion sortante vers un IdP externe ni aucun navigateur n'a été ouvert pendant le bootstrap

#### Scenario: Auth locale reste utilisable après activation d'OIDC
- **GIVEN** une instance avec des comptes locaux existants
- **WHEN** l'opérateur configure et active un IdP OIDC
- **THEN** les comptes locaux préexistants restent valides et peuvent toujours se connecter via `reconautctl login`
- **AND** les clés API personnelles déjà émises continuent de fonctionner sans rotation forcée

#### Scenario: OIDC activé en parallèle (cas avancé)
- **GIVEN** l'opérateur a configuré un IdP OIDC (par ex. Keycloak)
- **AND** un client capable de parler OIDC (par ex. un script de CI qui demande un access token)
- **WHEN** ce client présente un JWT valide à l'API
- **THEN** le JWT est vérifié à chaque requête, le claim de rôle drive l'autorisation
- **AND** les deux mécanismes coexistent ; rien n'oblige à utiliser OIDC pour l'usage interactif standard

#### Scenario: Panne de l'IdP externe ne bloque pas l'instance
- **GIVEN** un IdP OIDC est configuré et tombe (réseau coupé, IdP down)
- **WHEN** un opérateur tente de se connecter avec une clé API personnelle via `reconautctl`
- **THEN** la connexion réussit ; l'instance reste pleinement opérationnelle pour les utilisateurs locaux
- **AND** seules les nouvelles authentifications OIDC échouent avec un message explicite

#### Scenario: Viewer tente de déclencher un scan via la TUI
- **GIVEN** un utilisateur avec le rôle `viewer` (clé API personnelle)
- **WHEN** il lance `reconautctl scan request --target 192.0.2.10`
- **THEN** Rails répond HTTP 403 avec body `{ "error": "forbidden", "missing_role": "analyst" }`
- **AND** la TUI affiche un message d'erreur clair sans tenter d'autre action
- **AND** une entrée d'audit est écrite côté Rails

#### Scenario: Owner gère les rôles via la TUI
- **GIVEN** un utilisateur avec le rôle `owner`
- **WHEN** l'utilisateur exécute `reconautctl users grant <user> analyst` (ou équivalent)
- **THEN** le changement prend effet en moins de 60 secondes sur tous les services et est reflété dans le journal d'audit côté Rails
