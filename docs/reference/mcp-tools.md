# Référence des outils MCP

Cette page est **générée automatiquement** par
`scripts/gen_mcp_tools_reference.rb` à partir de `Mcp::ToolRegistry`.
Ne pas éditer à la main — toute modification sera écrasée à la
prochaine régénération.

Tous les outils sont exposés sur `POST /mcp/tools/<name>` (cf.
[routes REST](rest-routes.md)). L'authentification se fait via
`Authorization: Bearer <api_key>` ; le scope de la clé doit couvrir
les scopes requis listés ci-dessous.

## `add_scope`

**Scope MCP requis** : `write:scopes`

**Paramètres** :

- `kind` : `enum`, **required**
- `value` : `string`, **required** (min_length=1, max_length=255)

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/add_scope \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"kind":"ip","value":"192.0.2.10"}'
```

---

## `agent_chat`

**Scope MCP requis** : `agent:chat`

**Paramètres** :

- `prompt` : `string`, **required** (min_length=1, max_length=4000)
- `context` : `hash`, **optional** (default={})

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/agent_chat \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"modbus exposés en France"}'
```

---

## `export_report`

**Scope MCP requis** : `read:reports`

**Paramètres** :

- `filter` : `hash`, **required**
- `format` : `string`, **required** (min_length=3, max_length=16)

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/export_report \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"filter":{},"format":"json"}'
```

---

## `get_host`

**Scope MCP requis** : `read:hosts`

**Paramètres** :

- `host_id` : `string`, **required** (min_length=1, max_length=64)

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/get_host \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"host_id":"00000000-0000-0000-0000-000000000000"}'
```

---

## `get_scan_status`

**Scope MCP requis** : `read:scans`

**Paramètres** :

- `scan_id` : `string`, **required** (min_length=1, max_length=64)

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/get_scan_status \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"scan_id":"00000000-0000-0000-0000-000000000000"}'
```

---

## `ingest_scan_result`

**Scope MCP requis** : `write:scans`

**Paramètres** :

- `payload` : `hash`, **required**

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/ingest_scan_result \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"payload":{}}'
```

---

## `list_api_keys`

**Scope MCP requis** : `read:api_keys`

**Paramètres** :

_Aucun paramètre._

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/list_api_keys \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{}'
```

---

## `list_scans`

**Scope MCP requis** : `read:scans`

**Paramètres** :

- `limit` : `integer`, **optional** (min=1, max=200, default=50)

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/list_scans \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{}'
```

---

## `list_scopes`

**Scope MCP requis** : `read:scopes`

**Paramètres** :

_Aucun paramètre._

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/list_scopes \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{}'
```

---

## `request_scan`

**Scope MCP requis** : `write:scans`

**Paramètres** :

- `scan_kind` : `enum`, **required**
- `target_kind` : `enum`, **required**
- `target_value` : `string`, **required** (min_length=1, max_length=255)

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/request_scan \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"scan_kind":"tcp_probe","target_kind":"ip","target_value":"192.0.2.10"}'
```

---

## `revoke_api_key`

**Scope MCP requis** : `write:api_keys`

**Paramètres** :

- `id` : `string`, **required** (min_length=1, max_length=64)

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/revoke_api_key \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"id":"00000000-0000-0000-0000-000000000000"}'
```

---

## `revoke_scope`

**Scope MCP requis** : `write:scopes`

**Paramètres** :

- `id` : `string`, **required** (min_length=1, max_length=64)

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/revoke_scope \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"id":"00000000-0000-0000-0000-000000000000"}'
```

---

## `search_hosts`

**Scope MCP requis** : `read:hosts`

**Paramètres** :

- `query` : `string`, **required** (min_length=1, max_length=1000)
- `limit` : `integer`, **optional** (min=1, max=100, default=50)

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/search_hosts \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"modbus"}'
```

---

## `submit_heartbeat`

**Scope MCP requis** : `write:heartbeats`

**Paramètres** :

- `payload` : `hash`, **required**

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/submit_heartbeat \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"payload":{}}'
```

---

## `system_doctor`

**Scope MCP requis** : `read:health`

**Paramètres** :

_Aucun paramètre._

**Exemple** :

```sh
curl -X POST http://localhost:3000/mcp/tools/system_doctor \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{}'
```
