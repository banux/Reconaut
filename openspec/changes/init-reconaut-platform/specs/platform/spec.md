# Spec delta : platform

## ADDED Requirements

### Requirement: Single-Tenant Data Model
Reconaut est livré en mode **tenant unique** en v1. Le schéma de données ne comporte AUCUNE notion de tenant : pas de colonne `tenant_id`, pas de RLS par tenant, pas d'UI de gestion de tenants. Une instance = un opérateur = un périmètre d'actifs déclaré. Un MSSP qui veut servir N clients DOIT déployer N instances Reconaut indépendantes.

#### Scenario: Schéma DB sans colonne tenant_id
- **GIVEN** le schéma Postgres après les migrations initiales
- **WHEN** un linter de schéma s'exécute
- **THEN** aucune table métier (`hosts`, `services`, `certificates`, `scopes`, `scans`, `audit_log`, etc.) ne contient de colonne `tenant_id` ou équivalent

#### Scenario: API rejette tout paramètre de tenant
- **GIVEN** une instance Reconaut déployée
- **WHEN** un client envoie une requête avec un paramètre `tenant_id` ou un header `X-Tenant`
- **THEN** l'API renvoie HTTP 400 avec body `{ "error": "tenant_param_unsupported" }`

#### Scenario: UI ne propose pas de sélecteur de tenant
- **WHEN** un opérateur authentifié charge l'application web
- **THEN** aucun composant UI ne propose de basculer entre des tenants ; les concepts de tenant n'apparaissent ni dans la navigation ni dans les paramètres

### Requirement: Authentication and RBAC
L'authentification DOIT être **local-first** : tout déploiement de Reconaut DOIT supporter l'authentification locale (utilisateur/mot de passe Argon2id + clés API personnelles hashées) **sans dépendance externe**, et cette voie DOIT rester disponible et fonctionnelle indéfiniment, même si un IdP externe est configuré. **OIDC** (Keycloak, Authentik, Dex, etc.) PEUT être activé en parallèle par configuration ; les deux mécanismes coexistent. L'instance NE DOIT JAMAIS exiger un IdP externe pour démarrer ou pour permettre la connexion d'un opérateur. Les rôles `owner`, `admin`, `analyst`, `viewer` et `mcp_client` DOIVENT être imposés côté serveur sur chaque endpoint et chaque outil MCP, indépendamment du mécanisme d'authentification.

#### Scenario: Bootstrap initial sans IdP externe
- **GIVEN** une instance fraîchement déployée, sans configuration OIDC
- **WHEN** l'opérateur initial complète le bootstrap (par ex. première visite UI ou commande CLI)
- **THEN** un compte `owner` local est créé avec un mot de passe défini à l'enrôlement
- **AND** ce compte peut générer une clé API personnelle et l'utiliser pour appeler l'API et MCP
- **AND** aucune connexion sortante vers un IdP externe n'a lieu pendant le bootstrap

#### Scenario: Auth locale reste utilisable après activation d'OIDC
- **GIVEN** une instance avec des comptes locaux existants
- **WHEN** l'opérateur configure et active un IdP OIDC
- **THEN** les comptes locaux préexistants restent valides et peuvent toujours se connecter
- **AND** les clés API personnelles déjà émises continuent de fonctionner sans rotation forcée

#### Scenario: OIDC activé en parallèle
- **GIVEN** l'opérateur a configuré un IdP OIDC (par ex. Keycloak)
- **WHEN** un utilisateur s'authentifie via OIDC
- **THEN** son JWT est vérifié à chaque requête, le claim de rôle drive l'autorisation
- **AND** les deux mécanismes coexistent et peuvent être utilisés par des utilisateurs distincts ou par le même utilisateur

#### Scenario: Panne de l'IdP externe ne bloque pas l'instance
- **GIVEN** un IdP OIDC est configuré et tombe (réseau coupé, IdP down)
- **WHEN** un opérateur tente de se connecter avec un compte local ou une clé API personnelle
- **THEN** la connexion réussit ; l'instance reste pleinement opérationnelle pour les utilisateurs locaux
- **AND** seules les nouvelles connexions OIDC échouent avec un message explicite

#### Scenario: Viewer tente de déclencher un scan
- **GIVEN** un utilisateur avec le rôle `viewer` (peu importe le mécanisme d'auth)
- **WHEN** l'utilisateur appelle `POST /scans`
- **THEN** l'API renvoie HTTP 403 avec body `{ "error": "forbidden", "missing_role": "analyst" }`
- **AND** une entrée d'audit est écrite

#### Scenario: Owner gère les rôles
- **GIVEN** un utilisateur avec le rôle `owner`
- **WHEN** l'utilisateur accorde le rôle `analyst` à un autre utilisateur
- **THEN** le changement prend effet en moins de 60 secondes sur tous les services et est reflété dans le journal d'audit

### Requirement: Storage Without Object Store
La plateforme NE DOIT PAS dépendre d'un stockage objet S3-compatible (S3, MinIO, Azure Blob, GCS, etc.) en v1. Les artefacts générés par la plateforme (exports de rapport, dumps de scope, archives de tier froid, etc.) DOIVENT être persistés soit (a) dans un volume filesystem local monté sur l'instance, soit (b) comme blobs Postgres (`bytea` ou `lob`), au choix selon la nature du payload. Cette contrainte préserve le caractère self-hostable de l'instance sans dépendance d'infrastructure cloud.

#### Scenario: Export de rapport écrit en filesystem
- **GIVEN** un opérateur déclenche un export `format=csv` via l'API
- **WHEN** Rails matérialise le rapport
- **THEN** le fichier est écrit sous `/var/lib/reconaut/exports/<uuid>.csv` (ou chemin équivalent monté en volume)
- **AND** l'URL de téléchargement renvoyée est servie par Rails (téléchargement authentifié), pas une URL signée S3

#### Scenario: Aucune dépendance S3 dans le déploiement
- **GIVEN** la configuration de déploiement de référence (`docker-compose.yml`, chart Helm)
- **WHEN** un linter scanne les services et les variables d'env
- **THEN** aucun service S3/MinIO/Azure Blob n'est référencé ; aucune variable `S3_*` / `AWS_*` / `MINIO_*` n'est requise pour démarrer
