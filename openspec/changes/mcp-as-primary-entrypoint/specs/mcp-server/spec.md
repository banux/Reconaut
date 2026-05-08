# Spec delta : mcp-server

## MODIFIED Requirements

### Requirement: MCP Tool Surface
La plateforme DOIT exposer un serveur Model Context Protocol sur le **transport HTTP+SSE uniquement** (le transport stdio n'est PAS livré en v1) comme **point d'entrée principal** des opérations Reconaut. Le périmètre des outils MCP DOIT couvrir **l'intégralité du workflow opérateur** — pas seulement la recherche et le scan, mais aussi la gestion du scope, la liste des scans, l'exploration d'hôtes, le chat conversationnel, le reporting, l'administration des utilisateurs / clés API, et le doctor de santé. Chaque outil DOIT être annoncé via le mécanisme de découverte MCP standard et porter un schéma de paramètres et de résultat typé.

Les outils livrés en v1 DOIVENT inclure au minimum :

- **Scope**
  - `list_scopes(filter?: object)` → liste d'entrées de scope (`id`, `kind`, `value`, `description`, `created_at`, `revoked_at`)
  - `add_scope(kind: string, value: string, description?: string)` → entrée créée
  - `revoke_scope(id: string)` → entrée mise à jour avec `revoked_at`
- **Scans**
  - `request_scan(target: object, options?: object)` → `{ scan_id }` (asynchrone). La cible DOIT être couverte par une entrée de scope active sinon la création du job est rejetée (cf. spec `scanning`).
  - `get_scan_status(scan_id: string)` → `{ status, progress, started_at, completed_at? }`
  - `list_scans(filter?: object, limit?: int)` → liste de résumés de scans
- **Hosts**
  - `search_hosts(query: string, filters?: object, limit?: int)` → liste de résumés d'hôtes
  - `get_host(host_id: string)` → enregistrement complet de l'hôte avec ses services
- **Agent**
  - `agent_chat(prompt: string, context?: object)` → réponse en streaming via `tool_result` partiels MCP HTTP+SSE. Chaque chunk porte un fragment de réponse + ses citations `(host_id, scanned_at)`.
- **Reports**
  - `export_report(filter: object, format: "json" | "csv" | "stix2")` → URL de téléchargement signée
- **Admin** (rôles `owner`/`admin` requis)
  - `list_users()` → liste d'utilisateurs locaux et OIDC
  - `grant_role(user_id: string, role: string)` → utilisateur mis à jour
  - `revoke_role(user_id: string, role: string)` → utilisateur mis à jour
  - `list_api_keys(user_id?: string)` → liste de métadonnées de clés (sans le secret)
  - `revoke_api_key(key_id: string)` → clé révoquée
- **Doctor**
  - `system_doctor()` → rapport `{ ok, checks: [{ name, status, details }] }` (cf. `Reconaut::Doctor`)

Le serveur MCP DOIT être joignable via TLS et authentifié par clé API personnelle à chaque connexion. **Une seule clé API personnelle** est utilisée par l'opérateur pour TOUS les usages — TUI et agents IA partagent la même clé.

#### Scenario: TUI invoque un outil de gestion de scope via MCP
- **GIVEN** un opérateur authentifié avec rôle `admin` et une clé API personnelle stockée localement
- **WHEN** le binaire `reconautctl scope add --kind cidr --value 192.0.2.0/24` invoque l'outil MCP `add_scope`
- **THEN** le serveur MCP exécute l'ajout via la même couche métier que tout autre client, écrit une ligne d'audit et renvoie l'entrée créée
- **AND** un test d'intégration confirme que le résultat retourné par le tool MCP est identique (au champ près) à celui qui aurait été retourné par un controller REST équivalent (utilisé en transition)

#### Scenario: Agent IA invoque l'outil agent_chat avec streaming
- **GIVEN** un agent IA externe authentifié avec une clé MCP scopée `read:hosts` et `agent:chat`
- **WHEN** l'agent invoque `agent_chat({"prompt": "modbus en France"})`
- **THEN** le serveur renvoie une suite de `tool_result` partiels via SSE, chaque chunk contenant un fragment de réponse + ses citations `(host_id, scanned_at)`
- **AND** un test d'intégration vérifie que la concaténation des chunks produit la réponse complète attendue

#### Scenario: Le transport stdio n'est pas exposé
- **WHEN** un client tente d'établir un canal MCP via stdio
- **THEN** aucun binaire de la plateforme n'expose un point d'entrée stdio MCP en v1 ; la documentation et les artefacts de release ne mentionnent que le transport HTTP+SSE

#### Scenario: TLS exigé en exposition publique
- **WHEN** un client tente une connexion HTTP+SSE en clair (sans TLS) vers le serveur MCP exposé publiquement
- **THEN** la connexion est refusée et la tentative est journalisée avec la raison `tls-required`
- **AND** un déploiement strictement interne avec mTLS au reverse proxy (cf. spec `mcp-server` originale, `tls.required=false posture=internal`) reste valide

#### Scenario: Une seule clé API par opérateur partagée TUI / MCP
- **GIVEN** un opérateur avec une clé API personnelle générée
- **WHEN** la même clé est utilisée pour appeler `add_scope` depuis `reconautctl` (TUI) puis `request_scan` depuis un agent IA externe
- **THEN** les deux appels réussissent
- **AND** chaque appel produit une ligne d'audit avec le `key_id` commun mais des `client_user_agent` distincts (`reconautctl/<version>` vs l'UA de l'agent)
- **AND** la révocation de la clé via `revoke_api_key` invalide simultanément les deux usages

### Requirement: MCP Authorization and Scopes
Chaque outil MCP DOIT déclarer un scope de moindre privilège, et le serveur DOIT rejeter les appels dont la clé API n'a pas le scope requis avec une erreur MCP structurée. La matrice de scopes DOIT couvrir la nouvelle surface étendue d'outils :

| Outil                | Scope requis           | Rôle minimum |
|----------------------|------------------------|--------------|
| `list_scopes`        | `read:scopes`          | viewer       |
| `add_scope`          | `write:scopes`         | admin        |
| `revoke_scope`       | `write:scopes`         | admin        |
| `request_scan`       | `write:scans`          | analyst      |
| `get_scan_status`    | `read:scans`           | viewer       |
| `list_scans`         | `read:scans`           | viewer       |
| `search_hosts`       | `read:hosts`           | viewer       |
| `get_host`           | `read:hosts`           | viewer       |
| `agent_chat`         | `agent:chat`           | analyst      |
| `export_report`      | `read:reports`         | viewer       |
| `list_users`         | `read:users`           | admin        |
| `grant_role`         | `write:users`          | owner        |
| `revoke_role`        | `write:users`          | owner        |
| `list_api_keys`      | `read:api_keys`        | admin        |
| `revoke_api_key`     | `write:api_keys`       | admin        |
| `system_doctor`      | `read:health`          | analyst      |

#### Scenario: Clé read-only tente une mutation via MCP
- **GIVEN** une clé API avec uniquement le scope `read:hosts`
- **WHEN** la clé invoque `add_scope`
- **THEN** le serveur renvoie le code d'erreur MCP `unauthorized` avec un message nommant le scope manquant `write:scopes`
- **AND** aucune mutation n'a lieu côté DB
- **AND** le rejet est journalisé dans le journal d'audit

#### Scenario: Clé multi-scopes réussit sur plusieurs outils
- **GIVEN** une clé avec les scopes `read:hosts`, `write:scans` et `agent:chat`
- **WHEN** la clé invoque `search_hosts`, puis `request_scan` (cible dans le scope), puis `agent_chat`
- **THEN** les trois appels réussissent et sont journalisés avec leurs noms d'outil respectifs

## ADDED Requirements

### Requirement: REST API Reduced to Bootstrap, Health and MCP Transport
L'API REST exposée par le process Rails DOIT être restreinte à trois familles d'endpoints non-MCP :

- **Auth bootstrap** :
  - `POST /auth/sessions` (échange email + password contre une session courte ou une clé API personnelle nouvellement générée),
  - `POST /auth/api_keys` (génération d'une clé API personnelle, requiert une session valide),
  - `DELETE /auth/sessions/{id}` (logout / révocation de session),
  - `DELETE /auth/api_keys/{id}` (révocation explicite — alternative à `revoke_api_key` MCP pour le cas où l'opérateur a perdu sa clé courante).
- **Healthcheck** : `GET /healthz` non authentifié, renvoie HTTP 200 si le process sert du trafic. Body minimal (`{"status":"ok"}`), sans donnée sensible.
- **Transport MCP** : les routes sous `/mcp/*` qui portent le serveur MCP HTTP+SSE.

Toute autre route REST (par ex. `/scopes`, `/scans`, `/agent/chat`, `/hosts`) qui existerait à l'instant `T` doit être considérée comme **dépréciée et migrée vers MCP**. L'introduction d'une nouvelle route REST hors de l'allowlist ci-dessus DOIT être bloquée par un linter CI dédié.

#### Scenario: Linter rejette une nouvelle route REST hors allowlist
- **GIVEN** une PR qui ajoute un nouveau controller `ReportsController` avec route `GET /reports`
- **WHEN** le linter `scripts/check_rest_allowlist.sh` s'exécute en CI
- **THEN** le check échoue avec le message `rest-route-not-allowed: GET /reports n'est pas dans l'allowlist (auth bootstrap / healthz / mcp transport)`
- **AND** la PR ne peut être fusionnée tant que la nouvelle fonctionnalité n'est pas portée comme outil MCP

#### Scenario: Healthcheck non authentifié reste accessible
- **WHEN** un client (LB k8s, prometheus blackbox, etc.) émet `GET /healthz` sans clé API
- **THEN** Rails répond HTTP 200 avec body `{"status":"ok"}`
- **AND** aucune ligne d'audit n'est écrite (le bruit serait disproportionné)

#### Scenario: L'auth bootstrap reste accessible sans MCP
- **GIVEN** une instance fraîchement déployée, aucun client n'a encore de clé API
- **WHEN** l'opérateur initial appelle `POST /auth/sessions` avec email + password locaux
- **THEN** Rails authentifie et renvoie une session ou émet une clé API personnelle
- **AND** une ligne d'audit est écrite avec `actor=<email>`, `action=auth.bootstrap`, `outcome=success|failure`
