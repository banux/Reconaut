# Spec delta : platform

## MODIFIED Requirements

### Requirement: Authentication and RBAC
L'authentification DOIT être **local-first** : tout déploiement de Reconaut DOIT supporter l'authentification locale (utilisateur/mot de passe Argon2id + clés API personnelles hashées) **sans dépendance externe**. La voie locale DOIT rester disponible et fonctionnelle indéfiniment, même si un IdP externe est configuré. **OIDC** (Keycloak, Authentik, Dex, etc.) PEUT être activé en parallèle par configuration ; les deux mécanismes coexistent. L'instance NE DOIT JAMAIS exiger un IdP externe pour démarrer ou pour permettre la connexion d'un opérateur.

Le canal d'accès opérateur de référence est le **binaire TUI `reconautctl`**, qui consomme le serveur **MCP HTTP+SSE** pour toutes les opérations métier après une étape initiale d'auth bootstrap. L'auth bootstrap est l'unique chemin REST que le binaire utilise — il ne peut pas faire autrement, puisqu'il n'a pas encore de clé API à présenter à MCP.

**Une seule clé API personnelle** est émise par opérateur et sert à tous ses usages (TUI et agents IA). Les rôles `owner`, `admin`, `analyst`, `viewer` et `mcp_client` DOIVENT être imposés côté serveur sur chaque endpoint et chaque outil MCP, indépendamment du mécanisme d'authentification.

#### Scenario: Bootstrap initial — REST puis MCP
- **GIVEN** une instance fraîchement déployée, sans configuration OIDC
- **WHEN** l'opérateur initial exécute `rails reconaut:bootstrap_owner` (création du compte) puis `reconautctl login`
- **THEN** `reconautctl` appelle `POST /auth/sessions` (REST) avec email + mot de passe pour obtenir une session courte
- **AND** `reconautctl` appelle ensuite `POST /auth/api_keys` (REST) pour générer la clé API personnelle
- **AND** la clé est stockée localement en `0600`
- **AND** toutes les commandes suivantes (`scope add`, `scan request`, `agent`, etc.) passent par MCP HTTP+SSE avec cette clé

#### Scenario: Le binaire ne parle pas REST hors auth bootstrap
- **GIVEN** un opérateur déjà loggué avec une clé API personnelle stockée
- **WHEN** l'opérateur lance `reconautctl scope add --kind cidr --value 192.0.2.0/24`
- **THEN** le binaire appelle `POST /mcp/<tool>` (où le serveur Rails route vers l'outil `add_scope`) — pas `POST /scopes`
- **AND** un test d'intégration en mode pcap (ou mock HTTP) confirme l'absence de toute requête REST sortante hors `/auth/*` et `/healthz`

#### Scenario: Auth locale reste utilisable après activation d'OIDC
- **GIVEN** une instance avec des comptes locaux existants
- **WHEN** l'opérateur configure et active un IdP OIDC
- **THEN** les comptes locaux préexistants restent valides ; `reconautctl login` continue de marcher
- **AND** les clés API personnelles déjà émises continuent de fonctionner sans rotation forcée

#### Scenario: Panne de l'IdP externe ne bloque pas l'instance
- **GIVEN** un IdP OIDC est configuré et tombe (réseau coupé, IdP down)
- **WHEN** un opérateur tente de se connecter via `reconautctl login` (auth locale)
- **THEN** la connexion réussit ; les opérations MCP avec sa clé API restent fonctionnelles
- **AND** seules les nouvelles authentifications OIDC échouent avec un message explicite

#### Scenario: Une seule clé API par opérateur sert TUI et MCP-AI
- **GIVEN** un opérateur avec une clé API personnelle générée via `reconautctl login`
- **WHEN** la même clé est utilisée pour appeler MCP depuis `reconautctl` (TUI) et depuis un agent IA externe
- **THEN** les deux appels réussissent
- **AND** chaque appel produit une ligne d'audit avec le même `key_id`
- **AND** la révocation de la clé via `revoke_api_key` (MCP) invalide simultanément les deux usages
