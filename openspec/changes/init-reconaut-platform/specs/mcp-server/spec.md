# Spec delta : mcp-server

## ADDED Requirements

### Requirement: MCP Tool Surface
La plateforme DOIT exposer un serveur Model Context Protocol sur le **transport HTTP+SSE uniquement** (le transport stdio n'est PAS livré en v1), annonçant les outils suivants — chacun gardé par une clé API scopée :

- `search_hosts` — `(query: string, filters?: object, limit?: int)` → liste de résumés d'hôtes
- `get_host` — `(host_id: string)` → enregistrement complet de l'hôte avec ses services
- `request_scan` — `(target: string, scope: object)` → `{ scan_id }` (asynchrone) ; la cible DOIT être couverte par une entrée de scope active sinon la création du job est rejetée par la spec `scanning`
- `get_scan_status` — `(scan_id: string)` → `{ status, progress, started_at, completed_at? }`
- `export_report` — `(filter: object, format: "json" | "csv" | "stix2")` → URL de téléchargement signée

Les clés API sont **scopées par utilisateur en mode single-tenant** et **scopées par tenant en mode multi-tenant**. Le serveur MCP DOIT être joignable via TLS lorsqu'il est exposé publiquement ; pour un déploiement strictement interne (réseau privé, mTLS amont), TLS au niveau MCP peut être délégué au reverse proxy — l'opérateur déclare cette posture par configuration et le boot logue la décision pour audit.

#### Scenario: Agent client recherche des hôtes via MCP
- **GIVEN** une clé API MCP avec le scope `read:hosts`
- **WHEN** le client invoque `search_hosts` avec `{"query": "nginx 1.18", "limit": 10}` sur le transport HTTP+SSE
- **THEN** le serveur renvoie au plus 10 enregistrements d'hôtes en contenu de résultat d'outil MCP
- **AND** l'appel est journalisé avec `key_id`, `tool_name`, `duration_ms` et `result_count`

#### Scenario: `request_scan` rejeté quand la cible est hors scope
- **GIVEN** une clé API avec le scope `write:scans` et aucune entrée de scope active couvrant `203.0.113.10`
- **WHEN** le client invoque `request_scan` avec `target=203.0.113.10`
- **THEN** le serveur renvoie une erreur MCP structurée `out-of-scope` ; aucun job n'est mis en file
- **AND** l'appel et le rejet sont journalisés dans le journal d'audit

#### Scenario: Le transport stdio n'est pas exposé
- **WHEN** un client tente d'établir un canal MCP via stdio
- **THEN** aucun binaire de la plateforme n'expose un point d'entrée stdio MCP en v1 ; la documentation et les artefacts de release ne mentionnent que le transport HTTP+SSE

#### Scenario: TLS exigé en exposition publique, optionnel en réseau privé
- **GIVEN** la configuration `mcp.tls.required=true` (défaut pour exposition publique)
- **WHEN** un client tente une connexion HTTP+SSE en clair
- **THEN** la connexion est refusée et la tentative est journalisée avec la raison `tls-required`
- **AND** quand la configuration `mcp.tls.required=false` est explicitement activée par l'opérateur (déploiement interne avec mTLS au reverse proxy), le serveur accepte les connexions amont en clair — le boot a logué cette posture pour audit

### Requirement: MCP Authorization and Scopes
Chaque outil MCP DOIT déclarer un scope de moindre privilège, et le serveur DOIT rejeter les appels dont la clé API n'a pas le scope requis avec une erreur MCP structurée. Les scopes disponibles incluent au minimum `read:hosts`, `write:scans`, `read:reports`, et `manage:scopes` (pour la mutation du scope déclaratif via MCP, si l'opérateur le souhaite).

#### Scenario: Clé en lecture seule tente un scan
- **GIVEN** une clé API avec uniquement le scope `read:hosts`
- **WHEN** la clé invoque `request_scan`
- **THEN** le serveur renvoie le code d'erreur MCP `unauthorized` avec un message nommant le scope manquant `write:scans`
- **AND** aucun job de scan n'est mis en file
- **AND** le rejet est journalisé dans le journal d'audit

#### Scenario: Clé multi-scopes réussit sur plusieurs outils
- **GIVEN** une clé avec les scopes `read:hosts` et `write:scans`
- **WHEN** la clé invoque `search_hosts` puis `request_scan` (cible dans le scope déclaré)
- **THEN** les deux appels réussissent et sont journalisés avec leurs noms d'outil respectifs
