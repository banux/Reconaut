# Spec delta : platform

## MODIFIED Requirements

### Requirement: Multi-Tenant Isolation (Opt-In)
La plateforme DOIT supporter deux modes de déploiement : **single-tenant (défaut)** et **multi-tenant (opt-in via flag de configuration)**. En mode single-tenant, un seul tenant implicite `default` existe ; les UI et API masquent les concepts de tenant ; la RLS est appliquée mais dégénérée à `tenant_id = 'default'`. En mode multi-tenant, l'isolation DOIT être imposée à la couche la plus basse possible — Row-Level Security Postgres, partitionnement de queue, préfixe par tenant sur le stockage objet — et l'accès cross-tenant DOIT être impossible par construction, pas par filtres applicatifs seuls.

#### Scenario: Single-tenant — concept de tenant masqué
- **GIVEN** le mode single-tenant (défaut)
- **WHEN** un utilisateur authentifié appelle l'API
- **THEN** les requêtes Postgres incluent `tenant_id = 'default'` (chemin RLS exercé)
- **AND** l'UI ne propose pas de sélecteur de tenant
- **AND** l'API rejette tout body comportant un `tenant_id` autre que `default` ou non spécifié

#### Scenario: Multi-tenant — tentative d'accès API cross-tenant
- **GIVEN** le mode multi-tenant est activé et un utilisateur authentifié comme tenant A
- **WHEN** cet utilisateur émet `GET /hosts/{id}` pour un `host_id` appartenant au tenant B
- **THEN** l'API renvoie HTTP 404 (pas 403) pour ne pas divulguer l'existence de la ligne
- **AND** un test d'intégration de 1000 appels confirme une variance de timing < 10 ms vs requêtes pour des IDs inexistants (pas d'oracle temporel)

#### Scenario: Multi-tenant — isolation par préfixe object store
- **GIVEN** le mode multi-tenant et les tenants A et B exportant tous deux des rapports
- **WHEN** le job d'export écrit dans le stockage objet
- **THEN** les objets du tenant A sont écrits sous le préfixe `t-A/...` avec une bucket policy refusant l'accès à tout rôle hors du scope IAM du tenant A

### Requirement: Authentication and RBAC
Les utilisateurs DOIVENT s'authentifier soit via **OIDC** (Keycloak, Authentik, Dex, etc.) **soit via un mécanisme local** (utilisateur/mot de passe Argon2id + clés API personnelles hashées). Le choix se fait au déploiement par configuration ; les deux modes peuvent coexister. Les rôles `owner`, `admin`, `analyst`, `viewer` et `mcp_client` DOIVENT être imposés côté serveur sur chaque endpoint et chaque outil MCP, indépendamment du mode d'authentification.

#### Scenario: Auth locale par défaut
- **GIVEN** une instance fraîchement déployée sans configuration OIDC
- **WHEN** l'opérateur initial complète le bootstrap
- **THEN** un compte `owner` local est créé avec un mot de passe défini à l'enrôlement
- **AND** ce compte peut générer une clé API personnelle et l'utiliser pour appeler l'API et MCP

#### Scenario: OIDC activé en parallèle
- **GIVEN** l'opérateur a configuré un IdP OIDC (par ex. Keycloak)
- **WHEN** un utilisateur s'authentifie via OIDC
- **THEN** son JWT est vérifié à chaque requête, le claim de rôle drive l'autorisation
- **AND** les comptes locaux préexistants restent valides ; les deux mécanismes coexistent

#### Scenario: Viewer tente de déclencher un scan
- **GIVEN** un utilisateur avec le rôle `viewer` (peu importe le mécanisme d'auth)
- **WHEN** l'utilisateur appelle `POST /scans`
- **THEN** l'API renvoie HTTP 403 avec body `{ "error": "forbidden", "missing_role": "analyst" }`
- **AND** une entrée d'audit est écrite

## REMOVED Requirements

### Requirement: Stripe EU Billing Integration
**Raison :** La facturation Stripe (Stripe EU + Stripe Tax, compteurs scans / appels MCP / dépassement de rétention, webhooks idempotents) n'a sa place que dans un produit SaaS commercial. Le projet OSS auto-hébergeable n'embarque pas de facturation. Si une offre managée commerciale est construite par un opérateur (le projet ou un tiers) au-dessus du même code, la facturation y vivra comme une couche externe, hors du périmètre du cœur. Les compteurs `scans_total`, `mcp_calls_total` etc. restent exposés comme métriques Prometheus pour l'observabilité opérateur, mais ne sont liés à aucun système de billing dans le cœur.

### Requirement: Multi-Region Active-Active EU as Invariant
**Raison :** L'exigence que la plateforme tourne simultanément dans deux régions EU read/write avec un retard de réplication p99 < 5 s était dimensionnée pour un SaaS critique. Pour un déploiement OSS auto-hébergé, le multi-région reste *possible* (Postgres standard) mais n'est plus un invariant cœur. La résidence configurable (cf. `gdpr-compliance / Configurable Data Residency`) couvre désormais le contrat de localisation des données, et l'opérateur choisit librement sa topologie (single-AZ, multi-AZ, multi-région, on-prem racks).
