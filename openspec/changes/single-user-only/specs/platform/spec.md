# Spec delta : platform

## MODIFIED Requirements

### Requirement: Authentication (Single Operator)
Reconaut est livré en mode **mono-user** en v1. Une instance = **un seul opérateur humain**, identifié par un mot de passe local hashé Argon2id. Aucune notion de rôle, aucun second compte, aucun mécanisme d'invitation. L'authentification DOIT se faire **localement** — pas de support OIDC ou autre IdP externe en v1. Un opérateur qui veut isoler plusieurs périmètres DOIT déployer plusieurs instances Reconaut indépendantes (cohérent avec le modèle tenant unique).

L'opérateur DOIT pouvoir générer **plusieurs clés API** rattachées à son compte unique, chacune portant son propre set de scopes MCP (défense-en-profondeur : la TUI prend une clé full-scope, un agent IA externe peut prendre une clé `read:hosts` + `read:scans` uniquement, etc.). La révocation d'une clé n'affecte pas les autres.

#### Scenario: Bootstrap initial pose le password de l'opérateur
- **GIVEN** une instance fraîchement déployée, sans password configuré
- **WHEN** l'opérateur exécute `rails reconaut:set_password` avec `RECONAUT_OPERATOR_PASSWORD=<password>`
- **THEN** le hash Argon2id du password est stocké dans la table `settings` (ou table `users` mono-row)
- **AND** un second appel sans flag `--rotate` est rejeté avec `password-already-set`

#### Scenario: Login échange password contre clé API
- **GIVEN** un password d'opérateur configuré
- **WHEN** un client appelle `POST /auth/sessions` avec `{"password": "<correct>"}`
- **THEN** Rails vérifie le hash et émet une clé API personnelle scopée selon la requête (par défaut : full-scope)
- **AND** une ligne d'audit est écrite avec `actor=operator`, `action=auth.login`

#### Scenario: Plusieurs clés API coexistent
- **GIVEN** l'opérateur a généré une première clé via `reconautctl login` (full-scope)
- **WHEN** l'opérateur génère une seconde clé via `POST /auth/api_keys` avec `{"scopes": ["read:hosts", "read:scans"]}`
- **THEN** les deux clés sont actives ; chacune apparaît dans `list_api_keys` (MCP) avec son propre `prefix`, ses `scopes` et son `created_at`
- **AND** la révocation de l'une n'affecte pas l'autre

#### Scenario: Tentative de créer un second utilisateur rejetée
- **GIVEN** un opérateur déjà configuré
- **WHEN** un client (par ex. via une route REST héritée) tente d'appeler un endpoint de création d'utilisateur
- **THEN** la requête est rejetée avec HTTP 404 (pas d'endpoint multi-user) ou HTTP 400 `multi_user_not_supported`
- **AND** un audit consigne la tentative

#### Scenario: Audit utilise le key_id de la clé courante
- **GIVEN** un opérateur authentifié avec une clé API
- **WHEN** une action quelconque est exécutée
- **THEN** la ligne d'audit porte `actor_key_id=<key_id de la clé courante>` (pas un `user_id` puisqu'il n'y en a qu'un implicite)
- **AND** un test parcourt l'audit log et confirme la présence de `actor_key_id` sur chaque ligne d'action

## REMOVED Requirements

### Requirement: Authentication and RBAC (multi-rôle, OIDC compatible)
**Raison** : Le modèle multi-user à cinq rôles (`owner`, `admin`, `analyst`, `viewer`, `mcp_client`) est retiré. Reconaut bascule en mode mono-user (cf. nouveau Requirement `Authentication (Single Operator)`). OIDC est retiré du périmètre v1 — il n'a pas de sens quand il n'y a qu'un seul compte local.

L'exigence retirée prévoyait :
- Cinq rôles imposés côté serveur sur chaque endpoint et chaque outil MCP.
- Auth locale + OIDC en parallèle, panne de l'IdP n'affectant pas les comptes locaux.
- Workflow de gestion de rôles (`grant_role`, `revoke_role`) accessible aux owners.

Tout cela est remplacé par le modèle simple : un opérateur, un password, N clés API scopées.
