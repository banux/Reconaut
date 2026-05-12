# Spec delta : scanning

## ADDED Requirements

### Requirement: Postgres-Backed Scanner Stores
Les binaires `scanner-<kind>` DOIVENT, quand `RECONAUT_DATABASE_URL` est défini et `--dry-run` n'est PAS passé, ouvrir une connexion Postgres via le pilote `pgx/v5/stdlib` (mode `database/sql`) et utiliser :

- `goodjob.SQLStore` pour consommer la file `good_jobs` (CLAIM / FINISH / FAIL),
- `results.SQLStore` pour persister les `Result` produits par les handlers via `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING`.

Le worker DOIT valider l'accessibilité de la DB au démarrage par un `db.PingContext()` avec un timeout strict ≤ 2 s, et **fail-fast** (exit ≠ 0) avec un message explicite si :

- l'URL est mal formée,
- la connexion échoue (refusée, timeout, auth invalide),
- les tables `good_jobs` ou `scan_results` n'existent pas.

Le mode `--dry-run` REMPLACE les deux stores par leurs variantes in-memory et n'ouvre aucune connexion DB — comportement préservé pour les workflows dev/test.

#### Scenario: Boot avec RECONAUT_DATABASE_URL valide → mode SQL
- **GIVEN** un Postgres local avec les tables `good_jobs` et `scan_results` migrées
- **WHEN** un binaire `scanner-dns_records` est lancé avec `RECONAUT_DATABASE_URL=postgresql://...` exporté et **sans** `--dry-run`
- **THEN** le binaire démarre, log `scanner-dns_records vX.Y.Z started (queue=scan:dns_records, dry-run=false)` puis attend des jobs
- **AND** un job inséré dans `good_jobs` est claimé, traité, et `scan_results` contient une nouvelle ligne avec l'`idempotency_key` du job
- **AND** un second insert avec le même `idempotency_key` retourne `(false, nil)` sans erreur (idempotence respectée)

#### Scenario: Boot avec RECONAUT_DATABASE_URL invalide → fail-fast clair
- **GIVEN** `RECONAUT_DATABASE_URL=postgresql://reconaut:wrong@127.0.0.1:5432/reconaut_test`
- **WHEN** le binaire est lancé
- **THEN** le binaire exit non-zéro dans ≤ 3 s
- **AND** stderr contient un message du type `scanner-<kind>: wire stores: db ping: ...` qui mentionne soit `connection refused`, `password authentication failed`, ou `database does not exist`
- **AND** le message ne contient PAS l'ancien `no DB driver linked` (l'invariant "pilote lié" est garanti par le blank import)

#### Scenario: Mode --dry-run sans DB → InMemory stores
- **GIVEN** aucune variable `RECONAUT_DATABASE_URL` exportée
- **WHEN** un binaire est lancé avec `--dry-run`
- **THEN** le binaire démarre, log `dry-run=true`, et utilise `goodjob.NewInMemoryStore()` + `results.NewInMemoryStore()`
- **AND** un job poussé via l'API in-memory de `goodjob` est traité et son résultat est lisible via `resStore.List()` (pas de side effect réseau)

#### Scenario: Ligne scan_results respecte l'idempotence
- **GIVEN** un worker connecté à Postgres
- **WHEN** le handler insère un Result avec `idempotency_key=K`, puis un second Result avec le même `K`
- **THEN** la table `scan_results` ne contient qu'**une seule** ligne avec cette clé
- **AND** `SQLStore.Insert` retourne `(true, nil)` au premier appel et `(false, nil)` au second
- **AND** la ligne stockée correspond au PREMIER Insert (le second n'écrase pas)

#### Scenario: results.SQLStore audit statique par sqlmock
- **GIVEN** un `*sql.DB` simulé par `go-sqlmock` configuré pour attendre le SQL exact :
  `INSERT INTO scan_results (idempotency_key, scan_kind, target_kind, target_value, status, observed_at) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (idempotency_key) DO NOTHING RETURNING idempotency_key`
- **WHEN** `results.NewSQLStore(db).Insert(ctx, Result{...})` est appelé
- **THEN** sqlmock confirme que la query attendue est passée avec les bons paramètres positionnels
- **AND** un test équivalent vérifie le chemin "conflict → 0 rows returned → inserted=false, err=nil"

## ADDED Requirements

### Requirement: Allowlist de licences pour pgx et go-sqlmock
Les nouvelles dépendances Go (`github.com/jackc/pgx/v5/stdlib`, `github.com/DATA-DOG/go-sqlmock`) DOIVENT figurer dans l'allowlist du job CI `api-license-audit` (ou son équivalent scanner), avec leurs licences identifiées **MIT** (pgx v5) et **MIT** (go-sqlmock). Toute future modification de licence amont déclenche un échec CI explicite.

#### Scenario: Audit licences passe avec pgx et go-sqlmock
- **GIVEN** la branche après l'ajout des dépendances
- **WHEN** le job `api-license-audit` (ou `scanner-license-audit`) tourne en CI
- **THEN** il liste `github.com/jackc/pgx/v5` et `github.com/DATA-DOG/go-sqlmock` parmi les dépendances autorisées
- **AND** exit 0
- **AND** si l'allowlist est retirée, exit non-zéro avec un message qui identifie la dépendance non autorisée
