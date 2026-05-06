# Spec delta : platform

## ADDED Requirements

### Requirement: Multi-Tenant Isolation
La plateforme DOIT imposer l'isolation tenant au niveau de la base de données (Row-Level Security Postgres ou schéma par tenant), du stockage objet (préfixe par tenant) et de la queue. L'accès cross-tenant DOIT être impossible par construction, pas par filtres applicatifs seuls. La plateforme étant multi-actif EU, l'isolation DOIT tenir dans chaque région et la réplication cross-région DOIT préserver les politiques RLS et les bucket policies.

#### Scenario: Tentative d'accès API cross-tenant
- **GIVEN** un utilisateur authentifié comme tenant A
- **WHEN** cet utilisateur émet `GET /hosts/{id}` pour un `host_id` appartenant au tenant B
- **THEN** l'API renvoie HTTP 404 (pas 403) pour ne pas divulguer l'existence de la ligne
- **AND** un test d'intégration de 1000 appels confirme une variance de timing < 10 ms vs requêtes pour des IDs inexistants (pas d'oracle temporel)

#### Scenario: Isolation par préfixe object store
- **GIVEN** les tenants A et B exportent tous deux des rapports
- **WHEN** le job d'export écrit dans le stockage objet
- **THEN** les objets du tenant A sont écrits sous le préfixe `t-A/...` avec une bucket policy refusant l'accès à tout rôle hors du scope IAM du tenant A

#### Scenario: Isolation cross-région
- **GIVEN** une ligne du tenant A répliquée d'`eu-west-3` vers `eu-central-1`
- **WHEN** un utilisateur authentifié comme tenant B tape contre `eu-central-1`
- **THEN** la RLS rejette toute lecture cross-tenant indépendamment de la région ; un test parcourt la matrice (région × tenant) et assure la non-fuite

### Requirement: Authentication and RBAC
Les utilisateurs DOIVENT s'authentifier via OIDC. Les rôles `owner`, `admin`, `analyst`, `viewer` et `mcp_client` DOIVENT être imposés côté serveur sur chaque endpoint et chaque outil MCP. Le choix concret de l'IdP est différé et n'altère pas ce contrat — toute implémentation OIDC conforme satisfait l'exigence.

#### Scenario: Viewer tente de déclencher un scan
- **GIVEN** un utilisateur avec le rôle `viewer`
- **WHEN** l'utilisateur appelle `POST /scans`
- **THEN** l'API renvoie HTTP 403 avec body `{ "error": "forbidden", "missing_role": "analyst" }`
- **AND** une entrée d'audit est écrite

#### Scenario: Owner gère les rôles
- **GIVEN** un utilisateur avec le rôle `owner`
- **WHEN** l'utilisateur accorde le rôle `analyst` à un autre utilisateur
- **THEN** le changement prend effet en moins de 60 secondes sur tous les services et est reflété dans le journal d'audit
