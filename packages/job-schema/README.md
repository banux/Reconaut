# packages/job-schema

Schemas JSON canoniques des messages echanges entre Rails et workers Go via
GoodJob. Versionnes (`schema_version: int`).

Schemas prevus :
- `ScanJobV1`
- `ScanResultV1`
- `Heartbeat`

Specs de reference :
- `openspec/changes/add-tech-stack/specs/architecture/spec.md`
  -> Requirement: Job Message Schema (versionne)

Statut : non encore defini. Itere via `add-tech-stack` section 3.1.
