# Référence des routes REST

Cette page est **générée automatiquement** par
`scripts/gen_rest_reference.rb` à partir de `apps/api/config/routes.rb`.
Ne pas éditer à la main — toute modification sera écrasée à la
prochaine régénération.

Reconaut expose une **API REST volontairement minimaliste** : seules
les 4 familles ci-dessous sont autorisées (cf.
[`mcp-as-primary-entrypoint`](https://github.com/banux/Reconaut/blob/main/openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md)
*Requirement: REST API Reduced to Bootstrap, Health and MCP Transport*).
Toute nouvelle route hors de ces familles est rejetée par le linter
CI [`scripts/check_rest_allowlist.sh`](https://github.com/banux/Reconaut/blob/main/scripts/check_rest_allowlist.sh).

Pour les opérations métier (scope, scan, agent, exports), utiliser les
[outils MCP](mcp-tools.md) sur `POST /mcp/tools/<name>`.

---

## Auth bootstrap

Endpoints REST nécessaires pour obtenir une clé API initiale (œuf et poule). Une fois la clé en main, les opérations passent par MCP.

| Verbe | Path | Controller#action | Exemple |
|-------|------|-------------------|---------|
| `GET` | `/auth/api_keys` | `auth/api_keys#index` | `curl -i http://localhost:3000/auth/api_keys` |
| `POST` | `/auth/api_keys` | `auth/api_keys#create` | `curl -X POST http://localhost:3000/auth/api_keys -d '...'` |
| `DELETE` | `/auth/api_keys/:id` | `auth/api_keys#destroy` | `curl -X DELETE http://localhost:3000/auth/api_keys/:id` |
| `POST` | `/auth/sessions` | `auth/sessions#create` | `curl -X POST http://localhost:3000/auth/sessions -d '...'` |

## Healthcheck

Probe non authentifié, dédié aux load balancers, k8s et probes Prometheus blackbox.

| Verbe | Path | Controller#action | Exemple |
|-------|------|-------------------|---------|
| `GET` | `/healthz` | `health#show` | `curl -i http://localhost:3000/healthz` |
| `GET` | `/up` | `rails/health#show` | `curl -i http://localhost:3000/up` |

## MCP tools

Surface canonique des outils Reconaut exposés via JSON-RPC HTTP+SSE. Voir [Référence des outils MCP](mcp-tools.md) pour le détail des paramètres.

| Verbe | Path | Controller#action | Exemple |
|-------|------|-------------------|---------|
| `GET` | `/mcp/tools` | `mcp/tools#list` | `curl -i http://localhost:3000/mcp/tools` |
| `POST` | `/mcp/tools/:tool_name` | `mcp/tools#invoke` | `curl -X POST http://localhost:3000/mcp/tools/:tool_name -d '...'` |

## MCP exports

Téléchargement one-shot des exports générés par le tool MCP `export_report` (URL signée HMAC-SHA256, TTL 1h, cf. [Exports MCP](../operating/mcp-exports.md)).

| Verbe | Path | Controller#action | Exemple |
|-------|------|-------------------|---------|
| `GET` | `/mcp/exports/:id` | `mcp/exports#download` | `curl -i http://localhost:3000/mcp/exports/:id` |
