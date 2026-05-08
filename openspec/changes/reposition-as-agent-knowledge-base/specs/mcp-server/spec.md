# Spec delta : mcp-server

## MODIFIED Requirements

### Requirement: MCP Tool Surface
La plateforme DOIT exposer un serveur Model Context Protocol sur le **transport HTTP+SSE uniquement** comme point d'entrée principal (cf. `mcp-as-primary-entrypoint`). Le périmètre des outils MCP DOIT couvrir l'intégralité du workflow opérateur **et l'intégration avec des outils externes** : la base de connaissance Reconaut est queryable et alimentée via la même surface MCP, sans canal alternatif.

Les outils livrés en v1 DOIVENT inclure au minimum (extensions par rapport à la matrice `single-user-only`) :

- **Scope** : `list_scopes`, `add_scope`, `revoke_scope`
- **Scans (collectes internes)** : `request_scan`, `get_scan_status`, `list_scans`
- **Scans (ingestion externe)** : **`ingest_scan_result`** — accepte un payload conforme `ScanResultV1` provenant d'un outil externe (cf. spec `integrations`).
- **Hosts** : `search_hosts`, `get_host`
- **Agent** : `agent_chat` (streaming SSE)
- **Reports** : `export_report`
- **API keys** : `list_api_keys`, `revoke_api_key`
- **Doctor** : `system_doctor`

#### Scenario: ingest_scan_result enregistré avec scope write:scans
- **GIVEN** la plateforme bootée
- **WHEN** un client liste les outils via `GET /mcp/tools`
- **THEN** `ingest_scan_result` figure dans la liste avec scope `write:scans`
- **AND** son schéma de paramètres référence le format `ScanResultV1`

#### Scenario: ingest_scan_result idempotent par idempotency_key
- **GIVEN** un payload `ScanResultV1` ingéré une première fois
- **WHEN** le même payload est ingéré une seconde fois
- **THEN** aucune ligne métier en double n'est créée (cf. spec `integrations` Requirement: Inbound Integration via ScanResultV1)
- **AND** une ligne d'audit `outcome=duplicate` est écrite

### Requirement: MCP Authorization and Scopes
Chaque outil MCP DOIT déclarer un scope de moindre privilège, et le serveur DOIT rejeter les appels dont la clé API n'a pas le scope requis avec une erreur MCP structurée. **La matrice ne fait pas référence à un rôle** (cf. `single-user-only`) — les scopes sont attachés aux clés API émises par l'opérateur unique.

| Outil                  | Scope requis           |
|------------------------|------------------------|
| `list_scopes`          | `read:scopes`          |
| `add_scope`            | `write:scopes`         |
| `revoke_scope`         | `write:scopes`         |
| `request_scan`         | `write:scans`          |
| `ingest_scan_result`   | `write:scans`          |
| `get_scan_status`      | `read:scans`           |
| `list_scans`           | `read:scans`           |
| `search_hosts`         | `read:hosts`           |
| `get_host`             | `read:hosts`           |
| `agent_chat`           | `agent:chat`           |
| `export_report`        | `read:reports`         |
| `list_api_keys`        | `read:api_keys`        |
| `revoke_api_key`       | `write:api_keys`       |
| `system_doctor`        | `read:health`          |

L'opérateur peut émettre des clés API ciblées : par exemple une clé `write:scans` uniquement, donnée à un wrapper nmap externe pour qu'il puisse pousser ses résultats sans avoir le droit de muter le scope.

#### Scenario: Clé d'ingestion limitée à write:scans
- **GIVEN** une clé API émise avec scopes `["write:scans"]` uniquement
- **WHEN** la clé invoque `ingest_scan_result` avec un payload valide ciblant un host dans le scope
- **THEN** l'ingestion réussit
- **AND** la même clé invoquant `add_scope` reçoit `unauthorized` nommant `write:scopes`
- **AND** un test confirme que la même clé ne peut pas non plus appeler `revoke_api_key` (manque `write:api_keys`)
