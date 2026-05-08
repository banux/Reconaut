# Spec delta : mcp-server

## MODIFIED Requirements

### Requirement: MCP Tool Surface
La plateforme DOIT exposer un serveur Model Context Protocol sur le **transport HTTP+SSE uniquement** comme point d'entrée principal (cf. `mcp-as-primary-entrypoint`). Le périmètre des outils MCP DOIT couvrir l'intégralité du workflow opérateur en mode mono-user.

Les outils livrés en v1 DOIVENT inclure au minimum :

- **Scope** : `list_scopes`, `add_scope`, `revoke_scope`
- **Scans** : `request_scan`, `get_scan_status`, `list_scans`
- **Hosts** : `search_hosts`, `get_host`
- **Agent** : `agent_chat` (streaming SSE)
- **Reports** : `export_report`
- **API keys** : `list_api_keys`, `revoke_api_key` — opèrent sur les clés du seul opérateur. **`list_api_keys` ne prend plus de paramètre `user_id`** (sans objet en mono-user).
- **Doctor** : `system_doctor`

**Outils retirés** par rapport à `mcp-as-primary-entrypoint` (encore non implémentés, donc retrait avant introduction) : `list_users`, `grant_role`, `revoke_role`. Justification : le modèle mono-user (cf. spec `platform` modifiée) supprime la notion de plusieurs utilisateurs et de rôles. `list_users` n'a pas d'objet ; `grant_role`/`revoke_role` non plus.

#### Scenario: list_api_keys ne prend pas de user_id
- **GIVEN** une instance avec un opérateur unique et trois clés API actives
- **WHEN** un client invoque `list_api_keys` (sans paramètre)
- **THEN** le serveur renvoie les trois clés avec leurs métadonnées (`id`, `prefix`, `scopes`, `created_at`, `revoked_at`)
- **AND** le schéma de paramètres déclaré pour cet outil est `{}`
- **AND** un test confirme que tenter d'appeler `list_api_keys({"user_id": "anything"})` est rejeté par le validateur de paramètres avec une erreur de paramètre inconnu (ou ignoré silencieusement selon le coercer en place)

#### Scenario: Outils admin user/role absents du registry
- **GIVEN** un client qui demande la liste des outils MCP via `GET /mcp/tools`
- **WHEN** la réponse est inspectée
- **THEN** aucun des noms `list_users`, `grant_role`, `revoke_role` n'apparaît
- **AND** un test grep confirme l'absence de toute trace de ces tools dans `apps/api/app/lib/mcp/core_tools.rb` après l'implémentation

### Requirement: MCP Authorization and Scopes
Chaque outil MCP DOIT déclarer un scope de moindre privilège, et le serveur DOIT rejeter les appels dont la clé API n'a pas le scope requis avec une erreur MCP structurée. **La matrice de scopes ne fait plus référence à un rôle** — il n'y a qu'un opérateur, et c'est le set de scopes attaché à la clé API qui détermine ce qu'elle peut faire.

| Outil                | Scope requis           |
|----------------------|------------------------|
| `list_scopes`        | `read:scopes`          |
| `add_scope`          | `write:scopes`         |
| `revoke_scope`       | `write:scopes`         |
| `request_scan`       | `write:scans`          |
| `get_scan_status`    | `read:scans`           |
| `list_scans`         | `read:scans`           |
| `search_hosts`       | `read:hosts`           |
| `get_host`           | `read:hosts`           |
| `agent_chat`         | `agent:chat`           |
| `export_report`      | `read:reports`         |
| `list_api_keys`      | `read:api_keys`        |
| `revoke_api_key`     | `write:api_keys`       |
| `system_doctor`      | `read:health`          |

Le **set de scopes par défaut** émis par `reconautctl login` est l'union de tous les scopes (full-scope). Une clé créée explicitement par l'opérateur via `POST /auth/api_keys` avec un body `{"scopes": [...]}` reçoit uniquement les scopes demandés, pour permettre la défense-en-profondeur (clé read-only pour un agent IA externe, par ex.).

#### Scenario: Clé read-only ne peut pas muter
- **GIVEN** une clé API émise avec scopes `["read:hosts", "read:scans"]`
- **WHEN** la clé invoque `add_scope`
- **THEN** le serveur renvoie le code d'erreur MCP `unauthorized` avec un message nommant le scope manquant `write:scopes`
- **AND** aucune mutation n'a lieu côté DB

#### Scenario: Clé full-scope (TUI par défaut) réussit sur tous les outils
- **GIVEN** une clé API émise via `reconautctl login` avec le set de scopes par défaut (full-scope)
- **WHEN** la clé invoque successivement `list_scopes`, `add_scope`, `request_scan` (cible dans le scope), `agent_chat`, `system_doctor`, `revoke_api_key` (sur une autre clé)
- **THEN** les six appels réussissent
- **AND** chaque appel produit une ligne d'audit avec `actor_key_id` = le `key_id` de la clé courante

## REMOVED Requirements

### Requirement: Tools `list_users` / `grant_role` / `revoke_role`
**Raison** : Ces outils étaient prévus dans `mcp-as-primary-entrypoint` (matrice multi-rôle) mais non encore implémentés. Le passage en mode mono-user (cf. spec `platform`) les rend sans objet. Aucune feature equivalent n'est introduite — un opérateur unique n'a personne à lister, à promouvoir, à révoquer.
