# Spec delta : platform

## ADDED Requirements

### Requirement: Workers émettent un heartbeat périodique
Chaque binaire `scanner-<kind>` DOIT émettre un heartbeat toutes les `RECONAUT_HEARTBEAT_INTERVAL` secondes (défaut 30) en appelant `POST /mcp/tools/submit_heartbeat` côté Rails. Le payload conforme à `HeartbeatV1` contient :

- `schema_version`: 1
- `worker_id`: la valeur de `RECONAUT_WORKER_ID` (ou la valeur dérivée par défaut `<kind>-<hostname>-<pid>`)
- `emitted_at`: timestamp RFC 3339
- `inflight_jobs`: nombre de jobs actuellement en cours de traitement (0 ou 1 typiquement)
- `version`: SemVer du binaire (depuis `worker.Version`)
- `scan_kind`: identifiant du kind (nouveau champ optionnel — ex. `"dns_records"`, `"service_fingerprint"`)

Le heartbeat DOIT être émis depuis une goroutine indépendante de la boucle de claim/submit. Un échec HTTP NE DOIT PAS interrompre la boucle ; il est loggé en `Warn` et retenté au tick suivant.

#### Scenario: worker boot → premier heartbeat dans la première minute
- **GIVEN** un binaire `scanner-dns_records` lancé avec `RECONAUT_API_URL`, `RECONAUT_API_KEY`, `RECONAUT_HEARTBEAT_INTERVAL=2` (test) — `RECONAUT_WORKER_ID="test-worker-A"`
- **WHEN** le binaire tourne pendant 5 secondes
- **THEN** au moins 2 appels `POST /mcp/tools/submit_heartbeat` sont émis (un test httptest server compte les requêtes reçues)
- **AND** chaque payload contient `worker_id="test-worker-A"`, `scan_kind="dns_records"`, `version` non vide.

#### Scenario: échec HTTP du heartbeat n'interrompt pas le claim loop
- **GIVEN** un faux serveur Rails qui répond 500 sur `/mcp/tools/submit_heartbeat` mais 200 sur `/mcp/tools/claim_scan_job`
- **WHEN** le worker tourne 5 secondes
- **THEN** la boucle de claim continue à appeler `claim_scan_job` normalement
- **AND** le worker log une `Warn` mais n'exit pas.

#### Scenario: shutdown propre annule la goroutine heartbeat
- **GIVEN** un worker en cours d'exécution
- **WHEN** SIGTERM est envoyé
- **THEN** la goroutine heartbeat se termine via `<-ctx.Done()` (vérifiable par un test qui mesure que la goroutine ne fuit pas après `cancel()`).

### Requirement: Schema HeartbeatV1 enrichi de `scan_kind`
Le schéma JSON `packages/job-schema/heartbeat_v1.json` DOIT inclure un champ `scan_kind` optionnel (string, max 64 chars). La validation reste backward-compatible : les anciens heartbeats sans ce champ continuent de passer.

#### Scenario: payload sans scan_kind reste valide
- **GIVEN** un payload `HeartbeatV1` qui n'inclut PAS `scan_kind`
- **WHEN** validé contre le schema
- **THEN** la validation passe (le champ est optionnel).

#### Scenario: payload avec scan_kind valide
- **GIVEN** un payload qui inclut `"scan_kind": "service_fingerprint"`
- **WHEN** validé
- **THEN** la validation passe et le champ est exposé par `Heartbeats::Record#to_h`.
