# Spec delta : mcp-server

## ADDED Requirements

### Requirement: MCP Tool `export_report`
La plateforme DOIT exposer un outil MCP `export_report` qui sérialise un sous-ensemble des données opérationnelles (scope, hosts, services, scans) dans l'un des trois formats `json`, `csv` ou `stix2` et renvoie une URL de téléchargement signée à durée de vie limitée.

L'outil DOIT respecter ces contraintes :

- **Paramètres** : `filter: { kind: "scope" | "hosts" | "services" | "scans", limit?: integer (1..10000, default 1000) }`, `format: "json" | "csv" | "stix2"`.
- **Réponse** : `{ download_url: "/mcp/exports/<uuid>", token: "<hex>", expires_at: "<iso8601>", format: "<format>", record_count: <int> }`.
- **TTL** : 1 heure par défaut (configurable via `RECONAUT_EXPORT_TTL_S`).
- **One-shot** : le fichier est supprimé après le premier téléchargement réussi.
- **Stockage filesystem** : `RECONAUT_EXPORT_DIR` (défaut `tmp/exports/`). Pas de S3.
- **Token** : HMAC-SHA256 calculé sur `(uuid || expires_at_iso)` avec `Rails.application.secret_key_base`, vérifié au temps constant (`Rack::Utils.secure_compare`).
- **Scope MCP requis** : `read:reports`.
- **Mode mono-user** : pas de filtre `tenant_id` (cf. `single-user-only`).

#### Scenario: export_report JSON renvoie une URL téléchargeable
- **GIVEN** une instance avec quelques hôtes en base et une clé API portant `read:reports`
- **WHEN** le client appelle `POST /mcp/tools/export_report` avec `{filter: {kind: "hosts", limit: 100}, format: "json"}`
- **THEN** la réponse 200 contient `download_url`, `token`, `expires_at` (≥ now+50min), `format=json`, `record_count` ≤ 100
- **AND** un `GET /mcp/exports/<uuid>?token=<token>` retourne 200 avec `Content-Type: application/json` et un Array JSON parseable

#### Scenario: Téléchargement one-shot consommé
- **GIVEN** une URL valide juste retournée par `export_report`
- **WHEN** le client la télécharge une première fois → 200 (succès)
- **AND** le client la télécharge une deuxième fois
- **THEN** la deuxième réponse est `404 Not Found`
- **AND** le fichier sous `RECONAUT_EXPORT_DIR` n'existe plus

#### Scenario: Token invalide ou expiré
- **GIVEN** un export généré et son URL
- **WHEN** le client modifie le token d'un caractère
- **THEN** la réponse est `404 Not Found` (PAS 401 — pour ne pas confirmer l'existence du fichier)
- **AND** le fichier reste sur disque (n'est pas supprimé par une tentative malveillante)

#### Scenario: Format CSV RFC4180 conforme
- **GIVEN** un export avec `format=csv` et 3 hôtes
- **WHEN** le client télécharge
- **THEN** le contenu est UTF-8, première ligne = headers (`id,ip,fqdn,first_seen_at,last_seen_at`), lignes suivantes = records, séparateur virgule, valeurs avec virgule sont quotées `"`
- **AND** le `Content-Type` est `text/csv`

#### Scenario: Format STIX2.1 minimal SCO-only
- **GIVEN** un export avec `format=stix2` et 2 hôtes (1 IP, 1 domain)
- **WHEN** le client télécharge
- **THEN** le contenu est un objet JSON avec `type: "bundle"`, `id` UUID, `objects: [...]`
- **AND** chaque host produit un SCO `ipv4-addr` ou `domain-name` (pas d'`indicator`, pas de `relationship` — minimal)
- **AND** le `Content-Type` est `application/stix+json;version=2.1`

#### Scenario: Filter limit respecté
- **GIVEN** une instance avec 50 hôtes et `filter.limit = 10`
- **WHEN** l'export est généré
- **THEN** `record_count = 10` dans la réponse
- **AND** le fichier téléchargé contient exactement 10 records

#### Scenario: Scope read:reports requis
- **GIVEN** une clé API qui n'a PAS le scope `read:reports`
- **WHEN** elle appelle `POST /mcp/tools/export_report`
- **THEN** la réponse est `403 rbac_forbidden` mentionnant `read:reports`
- **AND** aucun fichier n'est créé sous `RECONAUT_EXPORT_DIR`

### Requirement: No stdio MCP entrypoint
La plateforme NE DOIT JAMAIS exposer un point d'entrée MCP via stdio. Le transport unique est HTTP+SSE (cf. project.md). Toute introduction d'une lib MCP qui supporte stdio (`mcp-rb` en mode stdio, `python-mcp` stdio, `mcp-server-stdio`, etc.) ou tout pattern explicite (`MCP::Stdio`, `STDIO_TRANSPORT`, flag `--stdio`) DOIT faire échouer la CI.

#### Scenario: Linter `check_no_mcp_stdio.sh` rejette une introduction
- **GIVEN** un repo dans son état actuel (aucun stdio MCP)
- **WHEN** `bash scripts/check_no_mcp_stdio.sh` est exécuté
- **THEN** exit code 0
- **AND** un test du linter qui injecte temporairement `require "mcp-rb/stdio"` dans un fichier source confirme que le linter passe à exit ≠ 0

#### Scenario: Linter wired in CI stack-lint job
- **GIVEN** le workflow CI `.github/workflows/ci.yml`
- **WHEN** on inspecte le job `stack-lint`
- **THEN** la step `bash scripts/check_no_mcp_stdio.sh` est présente
- **AND** la step `bash scripts/check_no_mcp_stdio_test.sh` (test du linter) est présente

### Requirement: All Five Listed Tools Reachable via HTTP+SSE
Les cinq outils nommés par `init-reconaut-platform` §5.1 (`search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report`) DOIVENT tous être enregistrés dans `Mcp::ToolRegistry` au boot et accessibles via `POST /mcp/tools/<name>` avec une clé API portant le scope requis.

#### Scenario: Les 5 tools sont enregistrés
- **GIVEN** une instance fraîchement bootée avec `Mcp::CoreTools.register_all!` exécuté
- **WHEN** on appelle `GET /mcp/tools`
- **THEN** la liste retournée contient au moins les 5 noms : `search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report`
- **AND** chacun déclare son `scope` requis (`read:hosts`, `read:hosts`, `write:scans`, `read:scans`, `read:reports`)

#### Scenario: Chaque tool répond sur HTTP avec un payload schema-conforme
- **GIVEN** un test in-process qui exerce les 5 tools
- **WHEN** chaque tool est appelé avec des params valides
- **THEN** chaque réponse est 200 avec un body JSON qui respecte la forme `{tool: "<name>", result: {...}}`
- **AND** aucune réponse ne référence stdio ou un transport autre que HTTP+SSE
