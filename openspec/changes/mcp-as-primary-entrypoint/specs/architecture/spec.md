# Spec delta : architecture

## ADDED Requirements

### Requirement: MCP HTTP+SSE as Primary Entrypoint
Le serveur **MCP HTTP+SSE** intégré au process Rails DOIT être le **point d'entrée principal** pour toutes les interactions opérateur et agent IA avec Reconaut. Toute capacité fonctionnelle (gestion de scope, scan, recherche d'hôtes, chat conversationnel, reporting, administration utilisateurs/clés, doctor) DOIT être disponible comme outil MCP. Les clients (binaire TUI `reconautctl`, agents IA externes, scripts CI) DOIVENT consommer cette surface MCP plutôt qu'une API REST parallèle.

L'API REST exposée par le process Rails DOIT être restreinte à trois familles non-MCP : **auth bootstrap**, **healthcheck** (`GET /healthz` non authentifié), et **transport MCP** (`/mcp/*`). Toute nouvelle feature opérateur DOIT être ajoutée comme outil MCP, jamais comme nouveau controller REST.

#### Scenario: Toute nouvelle feature s'expose en outil MCP
- **GIVEN** une PR qui ajoute une nouvelle feature opérateur (par ex. « lister les vulnérabilités d'un host »)
- **WHEN** la PR est revue
- **THEN** la nouvelle feature est implémentée comme un outil MCP (`list_host_vulnerabilities` ou similaire) avec son schéma de paramètres typé et son scope RBAC
- **AND** aucune nouvelle route REST n'est introduite ; le linter `scripts/check_rest_allowlist.sh` rejette toute route hors de l'allowlist

#### Scenario: Le binaire reconautctl ne parle pas REST hors auth bootstrap
- **GIVEN** une revue automatisée du code Go de `apps/tui/`
- **WHEN** un linter scanne les URLs construites par le binaire
- **THEN** la seule URL non-MCP appelée est `POST /auth/sessions` (au login initial) et éventuellement `POST /auth/api_keys` (pour générer/régénérer la clé API)
- **AND** toutes les autres opérations passent par `/mcp/*`

### Requirement: Single API Key per Operator Across MCP Clients
Un opérateur DOIT pouvoir utiliser **une seule clé API personnelle** pour TOUS ses usages : TUI, agents IA externes, scripts CI. La plateforme NE DOIT PAS imposer de typer la clé par client (pas de `tui_key` vs `mcp_key`). La révocation d'une clé API DOIT couper simultanément tous les usages associés à cette clé.

#### Scenario: Une clé sert TUI et agent IA simultanément
- **GIVEN** un opérateur avec une clé API personnelle générée via `reconautctl login`
- **WHEN** la même clé est utilisée par `reconautctl scope list` (TUI) et par un agent IA Claude/GPT qui invoque `request_scan` via SDK MCP
- **THEN** les deux appels réussissent et sont journalisés avec le même `key_id`
- **AND** un test e2e exécute les deux appels en parallèle et confirme leur succès

#### Scenario: Révocation de clé coupe tous les clients
- **GIVEN** une clé API utilisée à la fois par la TUI d'un opérateur et par un agent IA externe
- **WHEN** un autre opérateur avec rôle `admin` invoque `revoke_api_key` via MCP
- **THEN** dans la minute, les deux clients reçoivent une erreur d'auth structurée sur leur prochain appel
- **AND** une ligne d'audit nomme la révocation, le révoquant et la clé révoquée

## MODIFIED Requirements

### Requirement: Frontend Interface
Le frontend opérateur de Reconaut DOIT être implémenté comme un **binaire Go** fournissant une **TUI** (Terminal User Interface) construite sur la suite Charm (`bubbletea` + `lipgloss` + `bubbles`, licence MIT, compatibles AGPL-3.0-only). Le binaire est nommé `reconautctl` et se distribue sous forme d'un binaire statique multi-arch indépendant des autres composants. **Aucun framework web** (Vue, React, Svelte, Angular, Solid, Nuxt, etc.) ne DOIT être livré dans le périmètre v1.

Le binaire `reconautctl` DOIT consommer le serveur **MCP HTTP+SSE** comme canal principal — les opérations métier (scope, scan, hosts, agent, doctor, admin) sont des invocations d'outils MCP. Le binaire ne parle l'API REST QUE pour le bootstrap d'auth (login, génération de clé API). Aucune logique métier n'est dupliquée côté binaire ; il n'est qu'un client MCP avec une UI terminal.

#### Scenario: Tentative d'introduire un framework web
- **GIVEN** une PR ajoute un répertoire `apps/web/` ou un fichier `*.vue`/`*.jsx`/`*.tsx`/`*.svelte` dans le repo
- **WHEN** le pipeline CI s'exécute
- **THEN** le check de stack rejette la PR avec le message `frontend-stack-violation: web frameworks not shipped in v1, use the Go TUI`

#### Scenario: La TUI consomme MCP comme canal principal
- **GIVEN** une revue automatisée du code Go de `apps/tui/`
- **WHEN** un linter compte les appels HTTP sortants groupés par chemin
- **THEN** la majorité des chemins commencent par `/mcp/`, et les seules exceptions sont `/auth/sessions` et `/auth/api_keys` (auth bootstrap)
- **AND** aucune URL `/scopes`, `/scans`, `/agent/chat`, `/hosts` n'est appelée par le binaire

#### Scenario: Le binaire reconautctl est un binaire statique Go
- **GIVEN** une release publiée
- **WHEN** un opérateur télécharge `reconautctl` pour son architecture
- **THEN** le binaire s'exécute sans installation préalable de runtime (pas de Node, pas de Ruby)
- **AND** `file reconautctl` confirme un binaire ELF/Mach-O statiquement linké pour l'arch attendue
