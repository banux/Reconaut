# Change : add-scanner-pgx-driver

## Pourquoi

Aujourd'hui les binaires `scanner-<kind>` refusent de booter quand `RECONAUT_DATABASE_URL` est exporté sans `--dry-run` :

```
scanner-dns_records: wire stores: no DB driver linked ; pass --dry-run for in-memory stores
exit status 1
```

La fonction `runtime.wireStores()` documente l'invariant : *"no DB driver linked"* — `init-reconaut-platform` a livré le squelette goodjob.SQLStore (`apps/scanner/internal/goodjob/sql.go`) mais **aucun pilote `database/sql` n'est enregistré** dans le binary, et `results.Store` n'a pas non plus d'implémentation SQL. Conséquence :

1. **Aucun worker Go ne peut écrire en base** aujourd'hui ; tout passe en `--dry-run` (in-memory) — y compris dans Helm/docker-compose en prod-like.
2. Les **résultats** émis par les sondeurs SSH, RDP, HTTP, DNS sont stockés en mémoire et perdus à chaque restart.
3. La file `good_jobs` n'est pas consommée par les binaires Go ; seul l'enqueue côté Rails fonctionne. Les jobs s'accumulent.

Ce change ferme le trou : pilote pgx-stdlib lié dans `internal/runtime`, `results.SQLStore` implémenté, migration Rails pour `scan_results`, et bascule du défaut `runtime.wireStores()` vers SQL quand `RECONAUT_DATABASE_URL` est présent.

## Ce qui change

1. **Pilote `database/sql` : `github.com/jackc/pgx/v5/stdlib`**.
   - Blank import dans `apps/scanner/internal/runtime/runtime.go` : `_ "github.com/jackc/pgx/v5/stdlib"`. Ça enregistre le driver `pgx` global, donc `sql.Open("pgx", url)` fonctionne dans TOUS les binaires `scanner-<kind>` sans modifier leur main.
   - Pilote pgx v5 sous **MIT** — compatible AGPL-3.0 (cf. policy `init-reconaut-platform` §1.3). À ajouter à l'allowlist `scripts/check_license_audit.sh` si présente.

2. **`results.SQLStore`** (nouveau fichier `apps/scanner/internal/results/sql.go`).
   - Implémente `Insert(ctx, r) → (inserted bool, err)` via :
     ```sql
     INSERT INTO scan_results (idempotency_key, scan_kind, target_kind, target_value, status, observed_at)
     VALUES ($1, $2, $3, $4, $5, $6)
     ON CONFLICT (idempotency_key) DO NOTHING
     RETURNING idempotency_key
     ```
     - `RETURNING` permet de distinguer insertion (1 row) vs conflit (0 row).
   - Implémente `List(ctx) → []Result` (ORDER BY observed_at ASC LIMIT 1000 — pour les tests/dev).
   - Constructeur `NewSQLStore(db *sql.DB) *SQLStore`.

3. **Migration Rails `db/migrate/<ts>_create_scan_results.rb`**.
   - Crée la table `scan_results` :
     ```ruby
     create_table :scan_results, id: false do |t|
       t.text     :idempotency_key, primary_key: true, null: false
       t.text     :scan_kind,     null: false
       t.text     :target_kind,   null: false
       t.text     :target_value,  null: false
       t.text     :status,        null: false  # JSON-encoded findings ou "ok"/"skipped"
       t.datetime :observed_at,   null: false
       t.timestamps default: -> { "NOW()" }
     end
     add_index :scan_results, :scan_kind
     add_index :scan_results, [:target_kind, :target_value]
     add_index :scan_results, :observed_at
     ```
   - Pas d'hypertable Timescale pour cette table en v1 (volume modéré, exposition à la requête côté Rails restera ad-hoc). Promotable plus tard.

4. **`runtime.wireStores()` bascule sur SQL quand `RECONAUT_DATABASE_URL` est présent**.
   - Ouvre `sql.Open("pgx", dbURL)`, configure `SetMaxOpenConns(8)` / `SetConnMaxLifetime(5 min)` / `SetMaxIdleConns(2)` (paramètres conservateurs pour un worker).
   - Pings le DB une fois au démarrage avec un context 2 s — échec → retour erreur claire `dial_error: <msg>` (au lieu du cryptique "no DB driver linked").
   - Construit `goodjob.NewSQLStore(db)` + `results.NewSQLStore(db)`.
   - Retourne `closeFn = func() { db.Close() }` pour shutdown propre.

5. **CI** :
   - Le job `api-rspec` migre déjà `scan_results` via `rails db:migrate` une fois la migration ajoutée — pas d'action CI supplémentaire.
   - Job `scanner-go` exécute `go test ./...` qui inclut maintenant des tests SQLStore via **`testcontainers-go` Postgres** ou directement contre la DB locale du runner si exportée. **Décision** : pas de testcontainers (lourd, network-dependent) ; les tests `results.SQLStore` tournent contre un mock `*sql.DB` via `github.com/DATA-DOG/go-sqlmock` (déjà MIT) **OU** sont sautés gracieusement quand `RECONAUT_TEST_DATABASE_URL` n'est pas exporté. **Choix retenu** : `go-sqlmock` (déterministe, pas de side effect réseau).

6. **`scripts/check_license_audit.sh`** : pgx v5 + go-sqlmock ajoutés à l'allowlist (MIT chacun).

## Contraintes

- **Aucune nouvelle dépendance non-MIT/Apache/BSD**. `pgx/v5` est MIT ; `go-sqlmock` est MIT ; pas de runtime CGO.
- **Aucun fallback silencieux DB → in-memory**. Si `RECONAUT_DATABASE_URL` est exporté et que la connexion échoue, le worker retourne exit=1 avec un message explicite — pas de bascule masquée en in-memory.
- **`--dry-run` reste le mode dev local** (no DB url required, in-memory stores) ; le comportement actuel est préservé.
- **Pas de migration destructrice**. La table `scan_results` est nouvelle ; aucun renommage / DROP.
- **Idempotence préservée**. Le contrat `Insert → (inserted bool, nil)` est maintenu : un conflit `idempotency_key` retourne `(false, nil)`, jamais une erreur.
- **Pas de couplage Rails ↔ Go nouveau**. La table `scan_results` est écrite par Go (worker) et lue par Rails (modèle léger plus tard, hors scope ici) — le couplage est la table elle-même, pas un RPC.
- **Idem pour `good_jobs`**. GoodJob crée déjà sa propre migration ; le SQLStore Go ne fait que lire/écrire les colonnes documentées (`finished_at`, `serialized_params`, etc.).
- **Pas de partitionnement Timescale en v1**. La table reste relationnelle classique. La migration sera promotable plus tard si besoin.

## Non-objectifs (hors scope de ce change)

- **Modèle ActiveRecord côté Rails pour `scan_results`** — différé. Rails peut interroger la table en raw SQL en attendant ; un AR model arrivera quand on aura un usage produit qui le motive.
- **Hypertable TimescaleDB pour `scan_results`** — différé. Si le volume explose, on promote ; pour la v1 on garde une table relationnelle.
- **Migration de `good_jobs` côté Go** — GoodJob gère sa migration côté Rails. Le SQLStore Go consomme la table existante.
- **Connection pooling avancé (pgBouncer, pgcat)** — différé. Les 8 conns max par worker suffisent pour la v1 (chaque worker tourne 1 goroutine de claim).
- **Migration vers `pgx` natif (sans `database/sql`)** — différé. Le mode `stdlib` suffit pour les requêtes du worker (claim, finish, insert).
- **TLS sslmode=verify-full** comme défaut — différé. Le worker hérite du `sslmode` exprimé dans `RECONAUT_DATABASE_URL`. Documentation prod recommandera `sslmode=require` minimum.

## Décisions prises

1. **pgx v5 plutôt que lib/pq**. lib/pq est en mode maintenance depuis 2021 ; pgx v5 est activement maintenu, MIT, et offre des perfs supérieures. Coût migration future = nul (`database/sql` masque le pilote).
2. **Mode `stdlib`** plutôt que pgx natif. Permet de réutiliser `goodjob.NewSQLStore(db Beginner)` existant sans refactor. Suffisant pour les queries simples.
3. **`go-sqlmock` plutôt que testcontainers**. Tests déterministes, < 100 ms, pas de réseau requis. Couvre les patterns de query (claim, insert ON CONFLICT, RETURNING) avec assertions sur SQL exact.
4. **Pas d'auto-migrate côté Go**. La création des tables reste 100% Rails (Zeitwerk pipeline, schéma versionné, rollback testable). Le worker Go assume que les tables existent — fail-fast au démarrage si la table `scan_results` est absente (message explicite).
5. **Ping au démarrage avec timeout 2 s**. Court-circuite les boucles infinies "wait for DB" qui rendent le startup d'un workload Kubernetes opaque ; à la place, échec immédiat → restart kube → backoff exponentiel, déboggage clair.
6. **`MaxOpenConns=8`**. Un worker fait 1 goroutine de claim + handlers (qui peuvent appeler la DB pour persister un résultat). 8 conns laissent de la marge sans monopoliser le pool Postgres.

## Différé (non bloquant, parqué pour plus tard)

- **`add-scan-results-ar-model`** : un modèle ActiveRecord côté Rails pour exposer `scan_results` via MCP (`get_scan_result`, `list_scan_results`).
- **`add-scan-results-hypertable`** : promotion `scan_results` → hypertable TimescaleDB quand le volume justifie.
- **`add-pgx-native`** : passage de `database/sql` à `pgx.Conn` natif pour profiter du COPY / batch / prepared statements optimisés (utile si le débit de résultats devient un goulot).
- **`add-pgbouncer-prod`** : recommandations Helm pour faire passer les workers Go derrière pgBouncer en prod multi-replica.
