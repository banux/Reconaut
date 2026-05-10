# Reconaut — base de connaissance pour agents IA

Statut : **acté** par le change [`reposition-as-agent-knowledge-base`](https://github.com/banux/Reconaut/blob/main/openspec/changes/reposition-as-agent-knowledge-base/proposal.md).
Audience : opérateur qui évalue Reconaut, contributeur qui veut comprendre où va le produit.

## TL;DR

- **Reconaut n'est pas un produit autonome de scan-puis-rapport.** C'est un **composant** de la stack sécurité de l'opérateur — une **base de connaissance d'actifs internet** queryable via MCP HTTP+SSE.
- Le **persona principal** est l'opérateur qui orchestre des agents IA (Reconaut's own agent + agents externes type Claude / GPT / agents maison) contre sa surface d'attaque et veut leur donner une **source d'autorité** partagée.
- Reconaut accepte des **données entrantes** (scans internes ET ingestion de scanners externes via `ingest_scan_result`) et expose des **flux sortants** (outils MCP de lecture + futurs webhooks).
- C'est un OSS auto-hébergeable, mono-user, scope-driven, sous AGPL-3.0-only.

## Le persona

Auparavant, Reconaut visait l'analyste SOC qui clique dans une UI. Avec le pivot MCP-first ([`mcp-as-primary-entrypoint`](https://github.com/banux/Reconaut/blob/main/openspec/changes/mcp-as-primary-entrypoint/)), la TUI Go ([`replace-web-with-tui`](https://github.com/banux/Reconaut/blob/main/openspec/changes/replace-web-with-tui/)) et le mono-user ([`single-user-only`](https://github.com/banux/Reconaut/blob/main/openspec/changes/single-user-only/)), ce persona ne tient plus.

**Le persona aujourd'hui** :

- **L'opérateur** = un humain (sécu, ingé infra, indépendant, tech lead d'une équipe) qui possède ou contrôle une surface d'actifs internet.
- **Ses outils** = un ou plusieurs agents IA (Claude, GPT, agents maison) qu'il interroge sur sa surface, plus des scripts CI, plus parfois une TUI directe.
- **Son besoin** = une **source d'autorité partagée** que tous ces consommateurs interrogent via le même canal (MCP), avec la même clé API personnelle, et qui contient à la fois les données collectées par Reconaut et les données poussées par d'autres outils.

L'opérateur ne veut pas un produit qui « fait son travail à sa place ». Il veut un **composant** qu'il intègre dans son workflow, qu'il peut alimenter depuis n'importe quel scanner externe (nmap, OpenVAS, Nuclei, exports Censys/Shodan, scripts maison), et qu'il peut interroger en langage naturel ou structurellement via ses agents.

## Les quatre piliers

### 1. Graphe d'actifs scopé

L'opérateur déclare son périmètre (CIDR, domaines, hôtes) via le tool MCP `add_scope`. Reconaut maintient un **graphe d'actifs** (Apache AGE sur Postgres) qui matérialise les relations hôte ↔ service ↔ certificat ↔ domaine. Le scanner refuse en dur les cibles hors scope ; l'ingestion externe applique la même garde.

### 2. Alimentation hybride : scans internes + ingestion externe

Reconaut alimente le graphe via deux chemins équivalents :

| Chemin              | Tool MCP          | Source                                                                                                |
|---------------------|-------------------|-------------------------------------------------------------------------------------------------------|
| **Scan interne**    | `request_scan`    | Workers Go (`apps/scanner/cmd/scanner-<kind>/`) — TCP, TLS, HTTP, subdomains, services, **DNS records** (A/AAAA/MX/NS/TXT/CAA/SOA/CNAME via `scanner-dns_records`, cf. change `add-dns-records-scanner`) |
| **Ingestion externe** | `ingest_scan_result` | Wrapper externe qui produit `ScanResultV1`                                                       |

Les deux chemins partagent le **même schéma de payload** (`ScanResultV1`, cf. `packages/job-schema/scan_result_v1.json`) et la **même couche d'ingestion** (`Reconaut::ScanResultIngestor`). Les rows portent un attribut `source` qui distingue l'origine (`internal`, `nmap`, `nuclei`, etc.) — un même hôte vu par plusieurs sources se matérialise avec une liste `sources`.

### 3. Consommation par agents IA via MCP

La consommation passe **exclusivement** par MCP HTTP+SSE :

- `search_hosts(query, filters?)` — recherche hybride graphe + vector.
- `get_host(host_id)` — enregistrement complet d'un hôte avec services et certificats.
- `agent_chat(prompt)` — réponse en streaming via `tool_result` partiels SSE, avec citations `(host_id, scanned_at)` sur chaque chunk.
- `list_scans`, `get_scan_status`, `list_scopes`, `system_doctor`, etc.

Le persona-clé : **un agent IA externe** (Claude SDK, OpenAI Assistants, n'importe quel SDK MCP) consomme les mêmes outils que la TUI `reconautctl`, avec la même clé API, pour répondre à des questions du type « quels hôtes en France exposent du Modbus » ou « liste les certificats qui expirent dans 30 jours ».

### 4. Intégrations citoyennes de première classe

Reconaut **n'est pas** un silo. C'est un composant de la stack :

- **Entrée** : `ingest_scan_result` MCP — n'importe quel outil (script bash + curl, wrapper Python, intégration CI) qui produit un `ScanResultV1` peut alimenter le graphe.
- **Sortie** : outils MCP de lecture (graphe, recherche, export) + futurs webhooks (push vers SIEM, MISP, OpenCTI, etc., différé à un change ultérieur).

L'opérateur compose Reconaut avec ses propres outils plutôt que de migrer son workflow vers Reconaut. Reconaut **respecte la stack existante** au lieu de la concurrencer.

## Ce que Reconaut N'EST PAS

- ❌ **Un dashboard SOC autonome.** Pas de graphique de tendances, pas de heatmap de risque, pas de workflow ticketing intégré. L'opérateur compose ces capacités lui-même via ses propres outils + son agent IA qui interroge Reconaut.
- ❌ **Un outil multi-utilisateurs.** Une instance = un opérateur. Si plusieurs humains veulent travailler sur la même surface, ils déploient plusieurs instances (cf. [`single-user-only`](https://github.com/banux/Reconaut/blob/main/openspec/changes/single-user-only/)).
- ❌ **Un Shodan-like.** Pas de découverte du grand internet, pas de balayage non autorisé. Tout est scope-driven.
- ❌ **Un produit SaaS managé.** Distribution OSS auto-hébergée. AGPL-3.0-only.

## Architecture en bref

| Composant            | Rôle                                                              |
|----------------------|-------------------------------------------------------------------|
| **Rails 8** (`apps/api`) | Backend monolithe : MCP HTTP+SSE, agent conversationnel, audit, auth bootstrap. |
| **Workers Go** (`apps/scanner-<kind>/`) | Sondeurs spécialisés par `scan_kind`, consomment GoodJob.        |
| **TUI Go** (`apps/tui`) | Binaire `reconautctl` qui parle MCP HTTP+SSE (sauf login REST).   |
| **Postgres unique** | TimescaleDB (timeseries scan), pgvector (sémantique), Apache AGE (graphe). Pas de S3, pas de Redis. |
| **GoodJob**          | File de jobs Postgres. Pas de broker externe.                     |

## Liens

- [Proposal `reposition-as-agent-knowledge-base`](https://github.com/banux/Reconaut/blob/main/openspec/changes/reposition-as-agent-knowledge-base/proposal.md) — la décision et son raisonnement.
- [`docs/architecture/mcp-first.md`](../architecture/mcp-first.md) — pourquoi MCP est le canal principal.
- [`docs/integrations/external-scanners.md`](../integrations/external-scanners.md) — comment pousser un résultat de scan externe via `ingest_scan_result`.
- [Spec `integrations`](https://github.com/banux/Reconaut/blob/main/openspec/changes/reposition-as-agent-knowledge-base/specs/integrations/spec.md) — Requirement *Inbound Integration via ScanResultV1*.
