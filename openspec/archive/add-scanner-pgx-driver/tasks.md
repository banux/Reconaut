# Tâches : add-scanner-pgx-driver

Checklist du câblage du pilote pgx et de l'implémentation `results.SQLStore`, pour faire passer les workers Go en mode SQL par défaut. Chaque tâche inclut notes d'implémentation + test plan qui DOIT passer avant de cocher la case.

---

## 1. Pilote pgx et runtime

- [x] **1.1 Ajouter la dépendance `github.com/jackc/pgx/v5/stdlib`**
  - **Notes** : `cd apps/scanner && go get github.com/jackc/pgx/v5` puis `go mod tidy`. La version sélectionnée DOIT être ≥ v5.6.0 (versions stables récentes, MIT). `go.sum` est commité.
  - **Test plan** : `cd apps/scanner && go build ./...` reste vert. `head go.mod` montre `github.com/jackc/pgx/v5` en `require` direct.

- [x] **1.2 Blank import dans `internal/runtime/runtime.go`**
  - **Notes** : Ajouter `_ "github.com/jackc/pgx/v5/stdlib"` au bloc d'imports de `runtime.go`. Documente en commentaire ligne pourquoi le blank import : enregistre le pilote `pgx` auprès de `database/sql` sans le couplage explicite.
  - **Test plan** : `go vet ./internal/runtime/...` sans warning. Compile-time : un test qui appelle `sql.Drivers()` retourne un slice qui contient `"pgx"`.

- [x] **1.3 `runtime.wireStores()` bascule sur SQL par défaut**
  - **Notes** : Quand `dbURL != ""` ET `!dryRun` :
    1. `sql.Open("pgx", dbURL)` (jamais d'erreur même si DB inaccessible — Open est lazy).
    2. Configurer pool : `SetMaxOpenConns(8)`, `SetMaxIdleConns(2)`, `SetConnMaxLifetime(5*time.Minute)`.
    3. `db.PingContext(ctxWithTimeout(2s))` — sur erreur, fermer `db` et retourner `fmt.Errorf("db ping: %w", err)`.
    4. Wrap dans `goodjob.NewSQLStore(db)` + `results.NewSQLStore(db)`.
    5. `closeFn = func() { _ = db.Close() }`.
  - Le message d'erreur historique `"no DB driver linked"` est SUPPRIMÉ — il est remplacé par le ping error qui est plus informatif.
  - **Test plan** : Test unitaire dans `runtime_test.go` avec `RECONAUT_DATABASE_URL=postgres://...unreachable_port` → `Run()` retourne 1 et stderr contient `db ping`. Test : avec un URL valide local, `Run()` démarre puis exit propre sur SIGTERM dans un test go.

- [x] **1.4 Garder `--dry-run` intact**
  - **Notes** : Quand `dryRun=true`, sauter Open/Ping et continuer avec les InMemory stores comme aujourd'hui. Aucun changement de comportement attendu.
  - **Test plan** : Test existant `TestRun_DryRun` (s'il existe) reste vert. Sinon ajouter : binaire lancé avec `--dry-run --idle-backoff=10ms` se termine sur SIGTERM dans < 1 s, log mentionne `dry-run=true`, aucune connexion Postgres n'a été tentée (instrumentation via mock).

---

## 2. results.SQLStore

- [x] **2.1 Implémenter `apps/scanner/internal/results/sql.go`**
  - **Notes** : Nouveau fichier sous le package `results`. Expose :
    ```go
    type SQLStore struct { db *sql.DB }
    func NewSQLStore(db *sql.DB) *SQLStore
    func (s *SQLStore) Insert(ctx context.Context, r Result) (bool, error)
    func (s *SQLStore) List(ctx context.Context) ([]Result, error)
    ```
  - Insert : `INSERT INTO scan_results (idempotency_key, scan_kind, target_kind, target_value, status, observed_at) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (idempotency_key) DO NOTHING RETURNING idempotency_key`. Le `RETURNING` permet `Scan` : si row trouvée → inserted=true ; si `sql.ErrNoRows` → inserted=false, err=nil ; toute autre erreur remontée.
  - List : `SELECT idempotency_key, scan_kind, target_kind, target_value, status, observed_at FROM scan_results ORDER BY observed_at ASC LIMIT 1000`.
  - Rejette `IdempotencyKey=""` côté Go (avant de toucher la DB) avec `ErrMissingIdempotencyKey` — symétrique à `InMemoryStore`.
  - **Test plan** : Au moins 4 tests `sql_test.go` via `go-sqlmock` :
    1. Insert succès → mock voit la query, scanne 1 row, inserted=true.
    2. Insert conflict → mock retourne 0 rows (sql.ErrNoRows), inserted=false err=nil.
    3. Insert avec idempotency_key vide → erreur sans toucher la DB.
    4. List retourne N rows triées par observed_at ASC.

- [x] **2.2 Ajouter `github.com/DATA-DOG/go-sqlmock` aux deps de test**
  - **Notes** : `go get github.com/DATA-DOG/go-sqlmock` (MIT, devient une dépendance de test seulement — pas de blank import en prod). `go.sum` commité.
  - **Test plan** : `go test ./internal/results/...` vert. `grep -r "go-sqlmock" apps/scanner/internal/runtime/` confirme que le mock N'EST PAS importé par le code de prod.

---

## 3. Migration Rails

- [x] **3.1 Créer `apps/api/db/migrate/<ts>_create_scan_results.rb`**
  - **Notes** : Migration Rails 8 classique. Schéma exact :
    ```ruby
    create_table :scan_results, id: false do |t|
      t.text     :idempotency_key, null: false, primary_key: true
      t.text     :scan_kind,       null: false
      t.text     :target_kind,     null: false
      t.text     :target_value,    null: false
      t.text     :status,          null: false
      t.datetime :observed_at,     null: false
      t.timestamps default: -> { "NOW()" }
    end
    add_index :scan_results, :scan_kind
    add_index :scan_results, [:target_kind, :target_value]
    add_index :scan_results, :observed_at
    ```
  - Le timestamp `<ts>` est généré au moment du commit (par ex. `20260513000001`).
  - **Test plan** : `RAILS_ENV=test bundle exec rails db:migrate` passe. Test rspec `spec/db/scan_results_migration_spec.rb` : la table existe, PK = idempotency_key, 4 colonnes texte + observed_at timestamptz, 3 index attendus présents. Test : `INSERT INTO scan_results (...) ... ON CONFLICT (idempotency_key) DO NOTHING` exécutable sans erreur côté psql.

- [x] **3.2 Mettre à jour `db/structure.sql` si présent**
  - **Notes** : Vérifier si la stack utilise `db/structure.sql` (mode `schema_format = :sql` dans `config/application.rb`). Si oui, le fichier doit refléter la nouvelle table après `rails db:migrate`. Si non (mode `:ruby` avec schema.rb), pas d'action.
  - **Test plan** : `git diff db/structure.sql` (ou `db/schema.rb`) montre la table ajoutée si applicable.

---

## 4. CI et licences

- [x] **4.1 Mettre à jour `scripts/check_license_audit.sh` (ou équivalent)**
  - **Notes** : Si le repo a déjà un audit de licences Go, ajouter `github.com/jackc/pgx/v5` et `github.com/DATA-DOG/go-sqlmock` à l'allowlist avec leurs licences (MIT, MIT). Sinon, créer un audit minimal qui parse `go.mod` et vérifie que chaque dep figure dans une allowlist.
  - **Test plan** : `bash scripts/check_license_audit.sh` exit 0. Test : retirer pgx de l'allowlist temporairement → exit ≠ 0 + message qui pointe la dépendance.

- [x] **4.2 Vérifier `scripts/check_no_billing.sh` n'est pas faussement positif**
  - **Notes** : Vérifier que les patterns du linter no-billing ne matchent pas accidentellement sur `pgx` (très improbable mais à valider).
  - **Test plan** : `bash scripts/check_no_billing.sh` vert sur HEAD post-dépendance.

---

## 5. Documentation

- [x] **5.1 Mettre à jour `docs/operating/deployment-helm.md` et `deployment-docker-compose.md`**
  - **Notes** : Documenter que `RECONAUT_DATABASE_URL` est désormais OBLIGATOIRE pour les workers (sauf `--dry-run`). Recommander `sslmode=require` au minimum en prod. Indiquer le nombre max de conns par worker (8) pour calibrer `max_connections` côté Postgres.
  - **Test plan** : `grep -i "RECONAUT_DATABASE_URL" docs/operating/deployment-helm.md` retourne ≥ 1 match.

- [x] **5.2 Mettre à jour `docs/architecture/scan-frontier.md`**
  - **Notes** : Section "Principes intangibles" — la persistance des résultats est désormais Postgres-backed via `scan_results`, pas in-memory.
  - **Test plan** : `grep -i "scan_results" docs/architecture/scan-frontier.md` retourne ≥ 1 match.

---

## 6. Acceptance pour le change dans son ensemble

- [x] **6.1 Tests Go automatisés**
  - `cd apps/scanner && go test ./...` vert. Inclut les nouveaux tests `internal/results/sql_test.go` et `internal/runtime/runtime_test.go`.

- [x] **6.2 Tests Ruby automatisés**
  - `cd apps/api && bundle exec rspec spec/db/scan_results_migration_spec.rb` vert (avec DB up). Tolère DB unavailable via le pattern `@skip` éprouvé.

- [x] **6.3 Run e2e manuel documenté**
  - `RECONAUT_DATABASE_URL=postgresql://reconaut:reconaut_dev_password@localhost:5432/reconaut_development go run ./cmd/scanner-dns_records` démarre, attend des jobs, et n'affiche plus `no DB driver linked`. Procédure documentée dans `deployment-docker-compose.md`.

- [x] **6.4 Aucune régression**
  - Toute la suite Go + Ruby reste verte. Les binaires `scanner-<kind>` ne lancés sans modifs supplémentaires (le wireup runtime est centralisé).

- [x] **6.5 Audit dépendances**
  - 2 nouvelles dépendances seulement : `github.com/jackc/pgx/v5` (direct, MIT) + `github.com/DATA-DOG/go-sqlmock` (test-only, MIT). `go mod tidy && git diff go.mod go.sum` montre uniquement ces deux ajouts et leurs transitives.
