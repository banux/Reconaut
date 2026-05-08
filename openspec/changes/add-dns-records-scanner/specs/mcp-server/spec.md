# Spec delta : mcp-server

## MODIFIED Requirements

### Requirement: MCP Tool Surface
La plateforme DOIT exposer un serveur MCP HTTP+SSE comme point d'entrée principal (cf. `mcp-as-primary-entrypoint`). Le tool `request_scan` est étendu pour accepter le nouveau `scan_kind="dns_records"` qui résout les enregistrements DNS d'un domaine ou d'un host couvert par le scope.

Le `params_schema` de `request_scan` DOIT inclure `dns_records` dans l'enum `scan_kind`. La validation côté Rails DOIT rejeter une combinaison `scan_kind="dns_records"` avec un `target_kind` autre que `domain` ou `host` (un `target_kind="ip"` ou `cidr` n'a pas de sens — le worker n'a rien à résoudre).

| Outil          | Scope requis    | `scan_kind` accepté (extension)                                                                  |
|----------------|-----------------|--------------------------------------------------------------------------------------------------|
| `request_scan` | `write:scans`   | `tcp_probe`, `tls_capture`, `http_banner`, `subdomain_enum`, `service_fingerprint`, **`dns_records`** |

#### Scenario: request_scan accepte dns_records sur un domaine du scope
- **GIVEN** une clé API avec scope `write:scans` et un scope `domain:example.fr` actif
- **WHEN** la clé invoque `request_scan({"scan_kind":"dns_records","target_kind":"domain","target_value":"example.fr"})`
- **THEN** Rails répond `{ ok: true, scan_id: "...", idempotency_key: "scan-..." }` en moins de 100 ms
- **AND** un job est enqueueé sur la queue `scan:dns_records`

#### Scenario: dns_records avec target_kind=ip est rejeté
- **GIVEN** une clé API avec scope `write:scans`
- **WHEN** la clé invoque `request_scan({"scan_kind":"dns_records","target_kind":"ip","target_value":"192.0.2.10"})`
- **THEN** Rails répond `{ ok: false, error: "invalid_target", message: "dns_records requires target_kind in {domain, host}" }`
- **AND** aucun job n'est enqueueé

#### Scenario: dns_records hors scope rejeté
- **GIVEN** un scope qui ne couvre pas `example.org`
- **WHEN** un client invoque `request_scan({"scan_kind":"dns_records","target_kind":"domain","target_value":"example.org"})`
- **THEN** Rails répond `{ ok: false, error: "out-of-scope" }` (même code d'erreur que pour les autres `scan_kind`)
- **AND** une ligne d'audit `outcome=out-of-scope` est écrite

#### Scenario: GET /mcp/tools liste request_scan avec dns_records dans l'enum
- **WHEN** un client liste les outils via `GET /mcp/tools`
- **THEN** la réponse JSON contient un objet `request_scan` dont le schéma de paramètre `scan_kind` inclut la valeur `"dns_records"` dans son enum
