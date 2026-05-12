# Spec delta : scanning

## ADDED Requirements

### Requirement: Workers Go consomment la file via MCP HTTP, sans accès DB
Les binaires `scanner-<kind>` DOIVENT obtenir leurs jobs et soumettre leurs résultats **exclusivement** via le serveur MCP HTTP+SSE Rails. Ils NE DOIVENT JAMAIS établir de connexion Postgres :

- Aucun import `database/sql`, `github.com/lib/pq`, `github.com/jackc/pgx/*` dans `apps/scanner/internal/` ni `apps/scanner/cmd/` (linter statique `scripts/check_scanner_no_db_access.sh`).
- Aucune variable d'env `RECONAUT_DATABASE_URL` consommée par un binaire `scanner-<kind>`. La présence de la variable est ignorée.
- Le worker se configure via `RECONAUT_API_URL` (ex. `https://reconaut.example.com`) et `RECONAUT_API_KEY` (clé API portant les scopes `worker:claim` et `worker:submit`).

La boucle d'exécution d'un worker DOIT suivre le pattern :

```
loop:
  job ← claim_scan_job(queue="scan:<kind>", worker_id=...)
  if job.empty: sleep(idle_backoff); continue
  result, err ← handler(job)
  if err: fail_scan_job(job.id, err.Error())
  else:    submit_scan_result(job.id, result)
```

Le worker DOIT respecter le lease retourné par `claim_scan_job` (défaut 5 min) : si le job n'est pas finalisé (submit/fail) dans cet intervalle, Rails le considère expiré et le re-claimera côté autre worker. Le worker DOIT donc soit honorer son lease (faire un submit/fail à temps), soit ne pas s'inquiéter d'un double-traitement (l'idempotency_key protège côté Rails).

#### Scenario: Worker boot sans creds DB → connexion HTTPS exclusivement
- **GIVEN** un binaire `scanner-dns_records` lancé avec `RECONAUT_API_URL=https://api.local:3000`, `RECONAUT_API_KEY=k-abc` et **aucune** `RECONAUT_DATABASE_URL`
- **WHEN** le binaire démarre
- **THEN** il ne tente AUCUNE connexion vers le port Postgres (5432 ou autre) — vérifiable via `strace -e network` ou tcpdump en test d'intégration
- **AND** il fait un premier `POST /mcp/tools/claim_scan_job` vers `https://api.local:3000` avec `Authorization: Bearer k-abc`
- **AND** la réponse `{empty: true}` est traitée : sleep `idle_backoff` puis retry

#### Scenario: Worker reçoit un job, le traite, et submit le résultat
- **GIVEN** un worker connecté et Rails qui a 1 job dans `good_jobs` pour `scan:dns_records`
- **WHEN** le worker `claim_scan_job` → reçoit `{job: {id: "j-1", params: {...}, lease_until: "..."}, empty: false}`
- **THEN** le worker appelle son handler local (par ex. `dnsprobe.Resolve`), obtient un résultat
- **AND** le worker `submit_scan_result(job_id="j-1", idempotency_key=<from params>, ...)` réussit (status 200)
- **AND** côté Rails, `good_jobs[j-1].finished_at IS NOT NULL` et `scan_results` contient une ligne avec l'idempotency_key

#### Scenario: Worker crashe entre claim et submit → lease release re-queue
- **GIVEN** un worker qui a claim le job j-1 (Rails a set `performed_at=NOW()`) puis crashe
- **WHEN** ≥ 5 minutes s'écoulent sans submit ni fail
- **THEN** le recurring job de lease release remet `performed_at = NULL` pour j-1
- **AND** un autre worker (ou le même redémarré) peut claim j-1 normalement

#### Scenario: Double submit du même idempotency_key → 1 seule ligne
- **GIVEN** un worker qui submit avec succès le job j-1 (idempotency_key="k-1")
- **WHEN** le réseau hoquette et le worker retry submit avec le même idempotency_key
- **THEN** Rails accepte la requête (status 200) sans rejet
- **AND** `scan_results` contient UNE seule ligne avec idempotency_key="k-1" (ON CONFLICT DO NOTHING côté Rails)

#### Scenario: Lint statique — aucun import DB dans apps/scanner
- **GIVEN** le code source de `apps/scanner/`
- **WHEN** `scripts/check_scanner_no_db_access.sh` est exécuté en CI
- **THEN** il échoue (exit ≠ 0) si l'un des imports interdits apparaît dans un `.go` non-test : `database/sql`, `github.com/jackc/pgx/*`, `github.com/lib/pq`, `github.com/jackc/pgconn`
- **AND** un test contre un fixture qui ajoute volontairement `import "database/sql"` confirme la détection
- **AND** le linter est wired dans `.github/workflows/ci.yml` (job stack-lint)

## REMOVED Requirements

### Requirement: Postgres-Backed Scanner Stores
**Reason** : retiré au profit de l'accès via MCP HTTP. Les workers n'ouvrent plus de connexion `database/sql` et `runtime.wireStores` ne supporte plus le mode SQL.

**Migration** :
- `apps/scanner/internal/results/sql.go` et `sql_test.go` → supprimés.
- `apps/scanner/internal/goodjob/sql.go` → supprimé.
- `apps/scanner/internal/runtime/runtime.go` : `wireStores` ne sait plus que `--dry-run` (in-memory) ou `agentClient` (HTTP).
- Tests `TestPgxDriverRegistered`, `TestWireStores_BadURLFailsFast` → supprimés.
- La table `scan_results` (créée par migration `20260513000001`) est CONSERVÉE — c'est Rails qui y écrit désormais via le tool MCP `submit_scan_result`.

### Requirement: Allowlist de licences pour pgx et go-sqlmock
**Reason** : pgx et go-sqlmock ne sont plus dépendances de `apps/scanner/`. Leur entrée dans `scripts/check_scanner_deps_licenses.sh` est retirée. Le linter audit licences reste en place pour les autres dépendances Go.
