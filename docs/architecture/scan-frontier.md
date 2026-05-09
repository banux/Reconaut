# Frontiere Rails (apps/api) <-> workers Go (apps/scanner)

Cette page documente le contrat de message entre Rails et les workers
Go, et la procedure pour ajouter un nouveau type de scan.

Source de verite specs :
- `openspec/changes/add-tech-stack/specs/architecture/spec.md`
  - Requirement: Rails - Go Communication via GoodJob
  - Requirement: Scan Workers Runtime
- `openspec/changes/add-tech-stack/tasks.md` section 6.1

Voir aussi : [`mcp-first.md`](./mcp-first.md) pour comprendre comment
les outils MCP exposent les operations metier (request_scan,
list_scans, get_scan_status) au-dessus de cette frontiere — Rails
enqueue, les workers Go consomment, et l'operateur ou un agent IA
externe interroge l'etat via les outils MCP.

## scan_kind couverts en v1

| `scan_kind`           | Binaire                                          | Queue GoodJob              | Cible(s) acceptee(s)        |
|-----------------------|--------------------------------------------------|----------------------------|-----------------------------|
| `tcp_probe`           | `apps/scanner/cmd/scanner-tcp_probe/`            | `scan:tcp_probe`           | `ip`, `cidr`, `host`        |
| `tls_capture`         | `apps/scanner/cmd/scanner-tls_capture/`          | `scan:tls_capture`         | `ip`, `host`, `domain`      |
| `http_banner`         | `apps/scanner/cmd/scanner-http_banner/`          | `scan:http_banner`         | `ip`, `host`, `domain`      |
| `subdomain_enum`      | `apps/scanner/cmd/scanner-subdomain_enum/`       | `scan:subdomain_enum`      | `domain`                    |
| `service_fingerprint` | `apps/scanner/cmd/scanner-service_fingerprint/`  | `scan:service_fingerprint` | `ip`, `host`                |
| `dns_records`         | `apps/scanner/cmd/scanner-dns_records/`          | `scan:dns_records`         | `domain`, `host`            |

`dns_records` (cf. change [`add-dns-records-scanner`](../../openspec/changes/add-dns-records-scanner/proposal.md))
resout les enregistrements DNS publics (A, AAAA, MX, NS, TXT, CAA,
SOA, CNAME) d'un domaine couvert par le scope. Pas d'AXFR. Resolveur
configurable via `RECONAUT_DNS_RESOLVER`.

`service_fingerprint` (cf. change [`add-ssh-probe`](../../openspec/changes/add-ssh-probe/proposal.md))
expose le **premier sondeur applicatif livré** : SSH banner + host-key
SHA-256 sur TCP/22. Le sondeur ne tente JAMAIS d'authentification (pas
de password, pas de clé, pas de keyboard-interactive). Il capture la
host-key via `HostKeyCallback` puis interrompt le handshake AVANT toute
phase userauth ; un linter CI (`scripts/check_ssh_probe_no_auth.sh`)
garantit l'invariant. Timeout configurable via
`RECONAUT_SSH_PROBE_TIMEOUT` (défaut 5 s). Les sondeurs HTTP, RDP,
MQTT, CoAP, Modbus seront ajoutés par des changes dédiés.

## Principes intangibles

1. **Pas d'appel synchrone Rails -> Go.** Aucun HTTP, aucun gRPC, aucun
   RPC propriétaire. La seule sortance Rails vers le perimetre scan est
   l'enqueue dans la table `good_jobs` Postgres.
2. **Pas de logique de scan dans Rails.** Aucune ouverture de socket
   vers une cible, aucun parsing de réponse réseau d'une cible, aucun
   sondeur, aucun fingerprinter. Toute la couche réseau du scan vit
   dans `apps/scanner` (Go pur).
3. **Schemas versionnes.** Toute charge utile echangee respecte un
   schema JSON publie sous `packages/job-schema/`. Le champ
   `schema_version: int` est obligatoire.
4. **Idempotence.** Chaque message porte une `idempotency_key` stable.
   Les workers Go en font la clef de deduplication cote ingestion des
   resultats.
5. **At-least-once.** GoodJob garantit qu'un job est livre au moins une
   fois ; les retries sont gérés par GoodJob. Les workers doivent etre
   resilients aux relivraisons (cf. point 4).

## Schemas en vigueur

Tous trois sous `packages/job-schema/` :

| Schema           | Direction              | Description |
|------------------|------------------------|-------------|
| `ScanJobV1`      | Rails -> worker        | Demande de scan parametree |
| `ScanResultV1`   | worker -> Rails        | Resultat de scan, lie au job par `job_id` + `idempotency_key` |
| `HeartbeatV1`    | worker -> Rails        | Battement de coeur, etat du worker |

Les validateurs vivent ici :
- Rails : `apps/api/app/lib/job_schema/registry.rb` (gem `json-schema`,
  draft-06 force pour rester offline-friendly).
- Go : `apps/scanner/internal/jobschema/jobschema.go` (validateur maison
  zero-dependance).

## Comment ajouter un nouveau type de scan

1. **Etendre `ScanJobV1.scan_kind`**. Ajouter la nouvelle valeur a
   l'enum dans `packages/job-schema/scan_job_v1.json`. Bumper le
   `schema_version` SI un champ existant change de semantique ; sinon
   garder `1` et profiter de la retrocompatibilite ascendante (les
   workers a jour acceptent ; les workers anciens rejettent
   explicitement avec une erreur `schema_version_unsupported`).
2. **Mettre a jour les specs des deux validateurs.** Tests Rails
   (`spec/lib/job_schema/registry_spec.rb`) ET tests Go
   (`internal/jobschema/jobschema_test.go`). Les deux suites doivent
   passer.
3. **Implementer le handler Go.** Sous `apps/scanner/internal/<scan_kind>/`,
   un package qui expose une fonction `Run(ctx, params, target) (Result, error)`.
   Le binaire `scanner-worker` route par `scan_kind`.
4. **JAMAIS ecrire la logique cote Rails.** Le linter de stack
   (`scripts/check_stack.sh`) interdit toute ouverture de socket vers
   une cible depuis le code Rails.
5. **Ajouter la fixture d'integration.** Test bout-en-bout : Rails
   enqueue un job de ce kind, le worker Go le consomme, ecrit un
   `ScanResultV1`, Rails l'ingere.

## Anti-patterns

- **Faire un appel HTTP Rails -> scanner-worker** pour declencher un
  scan immediatement. Refuse par construction : pas d'API HTTP cote
  worker, pas de gem cliente RPC dans `apps/api`.
- **Mettre `tenant_id` dans le payload**. Reconaut est tenant unique
  (cf. spec `architecture` -> Single-Tenant Data Model).
- **Sucharger `findings` avec du XML / HTML brut**. Si une analyse
  necessite du parsing structure, declarer un schema typé sous
  `packages/job-schema/findings/<kind>_v1.json`.

## Fichiers connexes

- `packages/job-schema/scan_job_v1.json`
- `packages/job-schema/scan_result_v1.json`
- `packages/job-schema/heartbeat_v1.json`
- `apps/api/app/lib/job_schema/registry.rb`
- `apps/scanner/internal/jobschema/jobschema.go`
- `docs/architecture/worker-scaling.md` (deploiement, drain, retry)
