# apps/scanner

Workers Go, binaires statiques. Consomment la table `good_jobs` Postgres
directement via `SELECT ... FOR UPDATE SKIP LOCKED`. Pas de broker externe.

Specs de reference :
- `openspec/changes/add-tech-stack/specs/architecture/spec.md`
- `openspec/changes/init-reconaut-platform/specs/scanning/spec.md`

Statut : squelette non genere. Itere via `add-tech-stack` section 5.
