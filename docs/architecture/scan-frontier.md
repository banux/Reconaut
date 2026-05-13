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

`dns_records` (cf. change [`add-dns-records-scanner`](https://github.com/banux/Reconaut/blob/main/openspec/changes/add-dns-records-scanner/proposal.md))
resout les enregistrements DNS publics (A, AAAA, MX, NS, TXT, CAA,
SOA, CNAME) d'un domaine couvert par le scope. Pas d'AXFR. Resolveur
configurable via `RECONAUT_DNS_RESOLVER`.

`service_fingerprint` (cf. change [`add-ssh-probe`](https://github.com/banux/Reconaut/blob/main/openspec/changes/add-ssh-probe/proposal.md))
expose le **premier sondeur applicatif livré** : SSH banner + host-key
SHA-256 sur TCP/22. Le sondeur ne tente JAMAIS d'authentification (pas
de password, pas de clé, pas de keyboard-interactive). Il capture la
host-key via `HostKeyCallback` puis interrompt le handshake AVANT toute
phase userauth ; un linter CI (`scripts/check_ssh_probe_no_auth.sh`)
garantit l'invariant. Timeout configurable via
`RECONAUT_SSH_PROBE_TIMEOUT` (défaut 5 s).

`http_banner` (cf. change [`add-http-probe`](https://github.com/banux/Reconaut/blob/main/openspec/changes/add-http-probe/proposal.md))
expose le **deuxième sondeur applicatif livré** : HTTP et HTTPS sur
ports configurables. Le sondeur capture :

- `status`, `headers`, token `Server`, extrait HTML plafonné (32 KiB
  par défaut, max dur 1 MiB) ;
- en HTTPS : certificat TLS feuille (DER + SHA-256), SANs, `NotAfter`,
  négociation ALPN (`h2`, `http/1.1`).

Contraintes du sondeur (vérifiées statiquement par
`scripts/check_http_probe_no_offensive.sh`) : `GET` / `HEAD`
uniquement, pas d'`Authorization` header fabriqué, pas de redirect
suivi (on capture la réponse 30x telle quelle), pas de path traversal,
pas de payload weaponisé. TLS `InsecureSkipVerify=true` pour capturer
le cert même invalide / expiré / self-signed ; la validation est faite
a posteriori par la couche d'analyse Rails. Variables d'env :
`RECONAUT_HTTP_PROBE_TIMEOUT` (défaut 5 s),
`RECONAUT_HTTP_PROBE_MAX_BODY_KB` (défaut 32),
`RECONAUT_HTTP_PROBE_USER_AGENT` (défaut `Reconaut/<version> (+...)`).

Le binaire `service_fingerprint` couvre **aussi RDP** depuis
[`add-rdp-probe`](https://github.com/banux/Reconaut/blob/main/openspec/changes/add-rdp-probe/proposal.md) :
sur TCP/3389, il envoie un X.224 Connection Request portant un
RDP Negotiation Request, parse la `Connection Confirm` pour capturer
`protocol_version` + `security_flags` (`PROTOCOL_RDP|SSL|HYBRID|RDSTLS|
HYBRID_EX`), et — si `PROTOCOL_SSL` est annoncé — fait un handshake
TLS (`InsecureSkipVerify=true`) uniquement pour capturer le certificat
serveur (SHA-256, SANs, `NotAfter`). **Aucun message MCS Connect-Initial
n'est envoyé** ; aucun credential (password, NTLM, Kerberos, CredSSP)
n'apparaît jamais dans le code prod, garanti statiquement par
`scripts/check_rdp_probe_no_auth.sh`. Variables d'env :
`RECONAUT_RDP_PROBE_TIMEOUT` (défaut 5 s),
`RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE` (`true`/`1` pour désactiver
le capture du cert même si SSL annoncé).

Le binaire couvre aussi **MQTT** depuis
[`add-mqtt-probe`](https://github.com/banux/Reconaut/blob/main/openspec/changes/add-mqtt-probe/proposal.md) :
sur TCP/1883 et /8883, il envoie un **MQTT CONNECT** (clean session,
sans credential ni Will) puis lit le **CONNACK** pour récupérer le
`protocol_level`, le `return_code` (0=accepted, 1-5 = différents
refus standards) et le `session_present` flag. Aucun **PUBLISH /
SUBSCRIBE / UNSUBSCRIBE / PINGREQ** n'est émis ; sur port 8883, le
sondeur fait un handshake TLS pour capturer le cert avant le CONNECT.
Garanti statiquement par `scripts/check_mqtt_probe_no_auth.sh`.
Variables d'env : `RECONAUT_MQTT_PROBE_TIMEOUT`,
`RECONAUT_MQTT_PROBE_DISABLE_TLS_UPGRADE`.

Le binaire couvre aussi **CoAP** depuis
[`add-coap-probe`](https://github.com/banux/Reconaut/blob/main/openspec/changes/add-coap-probe/proposal.md) :
sur UDP/5683, il envoie un seul **GET `/.well-known/core`**
(RFC 6690, CoRE Link Format) en confirmable et capture le response
code, le content-format (option 12) et un excerpt du payload
(plafonné à 4 KiB). **Méthode = GET uniquement** ; aucun
PUT/POST/DELETE/Observe ; aucun broadcast multicast (`224.0.1.187`
refusé statiquement et au runtime). Garanti par
`scripts/check_coap_probe_no_offensive.sh`. Variable d'env :
`RECONAUT_COAP_PROBE_TIMEOUT`. DTLS (port 5684) est différé.

Le dernier sondeur §2.5, **Modbus**, sera ajouté par un change dédié.

## Principes intangibles

1. **Workers Go comme clients MCP de Rails.** Depuis
   [`remote-scanner-agents`](https://github.com/banux/Reconaut/blob/main/openspec/changes/remote-scanner-agents/proposal.md),
   les binaires `scanner-<kind>` n'ouvrent PLUS de connexion Postgres.
   Ils dialoguent EXCLUSIVEMENT avec Rails via MCP HTTPS — `claim_scan_job`
   pour réclamer le prochain job, `submit_scan_result` pour remonter le
   résultat, `fail_scan_job` pour reporter un échec. Un worker peut
   tourner n'importe où avec un outbound HTTPS : DMZ, infra client,
   edge geo.
2. **Pas de logique de scan dans Rails.** Aucune ouverture de socket
   vers une cible, aucun parsing de réponse réseau d'une cible, aucun
   sondeur, aucun fingerprinter. Toute la couche réseau du scan vit
   dans `apps/scanner` (Go pur).
3. **Schemas versionnes.** Toute charge utile echangee respecte un
   schema JSON publie sous `packages/job-schema/`. Le champ
   `schema_version: int` est obligatoire.
4. **Idempotence.** Chaque message porte une `idempotency_key` stable.
   Côté Rails, `submit_scan_result` fait `INSERT INTO scan_results
   ... ON CONFLICT (idempotency_key) DO NOTHING` — déduplication forte
   au niveau DB (PRIMARY KEY).
5. **At-least-once.** GoodJob (côté Rails uniquement) garantit qu'un
   job est livre au moins une fois ; les workers doivent etre
   resilients aux relivraisons (cf. point 4). Un worker qui crashe
   entre claim et submit voit son job ré-attribué par le recurring
   job `LeaseReleaseJob` après 5 minutes.

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
