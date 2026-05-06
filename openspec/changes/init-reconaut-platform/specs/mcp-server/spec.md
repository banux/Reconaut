# Spec delta : mcp-server

## ADDED Requirements

### Requirement: MCP Tool Surface
La plateforme DOIT exposer un serveur Model Context Protocol sur le **transport HTTP+SSE uniquement** (le transport stdio n'est PAS livré en v1), annonçant les outils suivants — chacun gardé par une clé API scopée tenant :

- `search_hosts` — `(query: string, filters?: object, limit?: int)` → liste de résumés d'hôtes
- `get_host` — `(host_id: string)` → enregistrement complet de l'hôte avec ses services
- `request_scan` — `(target: string, scope: object)` → `{ scan_id }` (asynchrone)
- `get_scan_status` — `(scan_id: string)` → `{ status, progress, started_at, completed_at? }`
- `export_report` — `(filter: object, format: "json" | "csv" | "stix2")` → URL de téléchargement signée

Le serveur MCP DOIT être joignable via TLS et authentifié par clé API tenant à chaque connexion.

#### Scenario: Agent client recherche des hôtes via MCP
- **GIVEN** un client a provisionné une clé API MCP avec le scope `read:hosts`
- **WHEN** le client invoque `search_hosts` avec `{"query": "nginx 1.18", "limit": 10}` sur le transport HTTP+SSE
- **THEN** le serveur renvoie au plus 10 enregistrements d'hôtes en contenu de résultat d'outil MCP
- **AND** l'appel est journalisé avec `key_id`, `tool_name`, `duration_ms` et `result_count`

#### Scenario: Le transport stdio n'est pas exposé
- **WHEN** un client tente d'établir un canal MCP via stdio
- **THEN** aucun binaire de la plateforme n'expose un point d'entrée stdio MCP en v1 ; la documentation et les artefacts de release ne mentionnent que le transport HTTP+SSE

#### Scenario: TLS exigé
- **WHEN** un client tente une connexion HTTP+SSE en clair (sans TLS) vers le serveur MCP
- **THEN** la connexion est refusée et la tentative est journalisée avec la raison `tls-required`

### Requirement: MCP Authorization and Scopes
Chaque outil MCP DOIT déclarer un scope de moindre privilège, et le serveur DOIT rejeter les appels dont la clé API n'a pas le scope requis avec une erreur MCP structurée.

#### Scenario: Clé en lecture seule tente un scan
- **GIVEN** une clé API avec uniquement le scope `read:hosts`
- **WHEN** la clé invoque `request_scan`
- **THEN** le serveur renvoie le code d'erreur MCP `unauthorized` avec un message nommant le scope manquant `write:scans`
- **AND** aucun job de scan n'est mis en file
- **AND** le rejet est journalisé dans le journal d'audit

#### Scenario: Clé multi-scopes réussit sur plusieurs outils
- **GIVEN** une clé avec les scopes `read:hosts` et `write:scans`
- **WHEN** la clé invoque `search_hosts` puis `request_scan`
- **THEN** les deux appels réussissent et sont journalisés avec leurs noms d'outil respectifs
