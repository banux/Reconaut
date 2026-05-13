# Tâches : remote-scanner-agents

Checklist du pivot worker SQL → worker MCP HTTP client. Chaque tâche inclut notes d'implémentation + test plan qui DOIT passer avant de cocher la case.

---

## 1. Côté Rails — MCP tools

- [x] **1.1 Scopes `worker:claim` et `worker:submit` enregistrés**
  - **Notes** : Étendre `Reconaut::ScopeRegistry` (cf. `apps/api/app/lib/reconaut/scope_registry.rb` ou équivalent) avec les deux scopes. Si le registre est sur des constantes, ajouter dans la liste.
  - **Test plan** : `spec/lib/reconaut/scope_registry_spec.rb` (créer ou étendre) — `expect(ScopeRegistry.known?("worker:claim")).to be true`, idem `worker:submit`.

- [x] **1.2 Use case `Scanner::ClaimJob`**
  - **Notes** : Nouveau use case sous `app/use_cases/scanner/claim_job.rb` (constante `Scanner::ClaimJob` — Zeitwerk-aligné, cf. fix Zeitwerk précédent). Signature : `call(queue:, worker_id:, lease_seconds: 300, caller_id:)`. Implémentation :
    1. `ActiveRecord::Base.transaction do`
    2. `row = GoodJob::Job.where(queue_name: queue, finished_at: nil).where("performed_at IS NULL OR performed_at < ?", lease_seconds.seconds.ago).lock("FOR UPDATE SKIP LOCKED").first`
    3. Si nil → `return Result.new(status: :ok, body: { empty: true })`.
    4. Lire `row.serialized_params` (JSON), extraire `target.kind`/`target.value`.
    5. Si target hors scope (via `Scopes::Storage` injecté) → `row.update!(finished_at: Time.current, error: "out-of-scope")` ; retourner `empty:true`.
    6. Sinon : `row.update!(performed_at: Time.current)` ; retourner `Result.new(status: :ok, body: { empty: false, job: { id: row.id, params: row.serialized_params, lease_until: (Time.current + lease_seconds.seconds).iso8601 } })`.
    7. `end transaction`.
  - **Test plan** : `spec/use_cases/scanner/claim_job_spec.rb` — 5 scenarios : (a) job pending in scope → claimé, performed_at set ; (b) file vide → empty:true ; (c) target hors scope → empty + finished_at + error="out-of-scope" ; (d) lease expiré → re-claimable ; (e) transaction rollback si lock impossible (concurrence).

- [x] **1.3 Use case `Scanner::SubmitResult`**
  - **Notes** : Sous `app/use_cases/scanner/submit_result.rb`. Signature : `call(job_id:, idempotency_key:, scan_kind:, target_kind:, target_value:, status:, observed_at:, caller_id:)`. Implémentation :
    1. Si `idempotency_key.blank?` → `Result.new(status: :bad_request, body: { error: "idempotency_key required" })`.
    2. `ActiveRecord::Base.transaction do`
    3. `ActiveRecord::Base.connection.execute("INSERT INTO scan_results (idempotency_key, scan_kind, target_kind, target_value, status, observed_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (idempotency_key) DO NOTHING", [...])` (utiliser `exec_query` avec binds pour SQL injection-safe).
    4. `GoodJob::Job.where(id: job_id, finished_at: nil).update_all(finished_at: Time.current)`.
    5. `Result.new(status: :ok, body: { ok: true })`.
  - **Test plan** : `spec/use_cases/scanner/submit_result_spec.rb` — (a) job en cours → submit OK + scan_results 1 ligne + finished_at set ; (b) double submit → idempotent (toujours 1 ligne, finished_at inchangé) ; (c) idempotency_key vide → 400.

- [x] **1.4 Use case `Scanner::FailJob`**
  - **Notes** : Sous `app/use_cases/scanner/fail_job.rb`. Signature : `call(job_id:, error:, caller_id:)`. Implémentation : `GoodJob::Job.where(id: job_id, finished_at: nil).update_all(finished_at: Time.current, error: error)` ; retourne `{ ok: true }`.
  - **Test plan** : `spec/use_cases/scanner/fail_job_spec.rb` — (a) job en cours → fail set ; (b) job déjà fini → no-op idempotent.

- [x] **1.5 3 tools MCP enregistrés dans `core_tools.rb`**
  - **Notes** : Ajouter dans `app/lib/mcp/core_tools.rb` :
    - `claim_scan_job` (scope `worker:claim`, params: queue, worker_id, lease_seconds?)
    - `submit_scan_result` (scope `worker:submit`, params: job_id, idempotency_key, scan_kind, target_kind, target_value, status, observed_at)
    - `fail_scan_job` (scope `worker:submit`, params: job_id, error)
  - Chaque tool invoque son use case avec `caller_id` extrait du contexte MCP.
  - **Test plan** : `spec/requests/mcp/scanner_tools_spec.rb` — 3 endpoints testés en request spec : (a) `POST /mcp/tools/claim_scan_job` avec scope OK → 200 + body shape ; (b) sans le scope → 403 ; (c) `submit_scan_result` idempotent ; (d) `fail_scan_job` met error.

- [x] **1.6 Recurring job de lease release**
  - **Notes** : Créer `app/jobs/lease_release_job.rb` (ActiveJob, queue `:maintenance`). Implémentation : `GoodJob::Job.where(finished_at: nil).where("performed_at IS NOT NULL AND performed_at < ?", 5.minutes.ago).update_all(performed_at: nil)`. Le scheduling se fait via `config/initializers/good_job_recurring.rb` (ou `config/good_job.rb`) avec cron `* * * * *` (chaque minute).
  - **Test plan** : `spec/jobs/lease_release_job_spec.rb` — (a) job avec performed_at > 5 min → re-queue ; (b) job avec performed_at < 5 min → laissé tel quel ; (c) job déjà finished → laissé tel quel.

---

## 2. Côté Go — agentclient + drop SQL

- [x] **2.1 Nouveau package `internal/agentclient/`**
  - **Notes** : Nouveau fichier `apps/scanner/internal/agentclient/client.go` qui expose :
    ```go
    type Client struct {
      apiURL, apiKey, workerID string
      httpClient *http.Client
    }
    type Job struct { ID string; Params map[string]any; LeaseUntil time.Time; Empty bool }
    func New(apiURL, apiKey, workerID string, tlsInsecure bool) *Client
    func (c *Client) Claim(ctx context.Context, queue string, leaseSeconds int) (*Job, error)
    func (c *Client) Submit(ctx context.Context, jobID, idemKey, scanKind, targetKind, targetValue, status string, observedAt time.Time) error
    func (c *Client) Fail(ctx context.Context, jobID, errMsg string) error
    ```
  - Format MCP HTTP : `POST {apiURL}/mcp/tools/<name>` avec header `Authorization: Bearer <key>`, body JSON `{params: {...}}`, réponse `{tool: "<name>", result: {...}}` (squelette aligné sur le client `reconautctl` existant — réutiliser le pattern).
  - Stdlib only : `net/http`, `encoding/json`, `crypto/tls` (pour InsecureSkipVerify quand `tlsInsecure=true`).
  - **Test plan** : `agentclient_test.go` via `httptest.NewServer` qui valide le shape des requêtes et retourne des fixtures : (a) Claim → job ; (b) Claim → empty ; (c) Submit OK ; (d) Submit erreur 400 ; (e) Fail OK ; (f) auth header présent avec `Bearer <key>`.

- [x] **2.2 Refactor `internal/runtime/runtime.go` → agentLoop**
  - **Notes** : Drop le wiring SQL. La fonction `Run` lit `RECONAUT_API_URL` + `RECONAUT_API_KEY` + `RECONAUT_WORKER_ID`, instancie `agentclient.New(...)`, et lance la boucle :
    ```
    for ctx not done:
      job, err := client.Claim(ctx, "scan:"+scanKind, leaseSeconds)
      if err: log + sleep backoff; continue
      if job.Empty: sleep idleBackoff; continue
      result, herr := handler(ctx, GoodjobJobFromAgentClient(job))
      if herr != nil: client.Fail(ctx, job.ID, herr.Error())
      else:           client.Submit(ctx, job.ID, idemKey, ...)
    ```
  - Le `--dry-run` mode reste : InMemory stores + un mock client qui ne fait rien (ou la `agentLoop` qui short-circuit).
  - Drop : `wireStores`, `pgx` blank import, tous les tests `TestPgxDriverRegistered` / `TestWireStores_*` deviennent obsolètes (supprimés).
  - **Test plan** : `runtime_test.go` mis à jour — un test bout-en-bout avec `httptest.Server` simule un Rails, le worker claim + submit ; un test `--dry-run` confirme aucun HTTP ; un test `RECONAUT_API_KEY` manquant → exit non-zéro.

- [x] **2.3 Supprimer `internal/results/sql.go` et `sql_test.go`**
  - **Notes** : Les fichiers du change précédent (`add-scanner-pgx-driver`) deviennent obsolètes. Le store SQL n'est plus utile côté Go — Rails écrit directement dans `scan_results` via le tool `submit_scan_result`.
  - **Test plan** : `git rm` les deux fichiers ; `go test ./internal/results/...` reste vert (les tests InMemory restent).

- [x] **2.4 Supprimer `internal/goodjob/sql.go`**
  - **Notes** : Idem — plus d'usage. La SQLStore goodjob disparaît, l'InMemory reste pour les tests + `--dry-run`.
  - **Test plan** : `go test ./internal/goodjob/...` reste vert (les tests InMemory restent).

- [x] **2.5 Drop des dépendances Go**
  - **Notes** : `go mod tidy` retire `github.com/jackc/pgx/v5`, `pgpassfile`, `pgservicefile`, `puddle/v2`, `DATA-DOG/go-sqlmock`. Vérifier qu'aucun import résiduel ne référence ces packages.
  - **Test plan** : `cd apps/scanner && go mod tidy && git diff go.mod go.sum` montre uniquement des suppressions. `go build ./...` reste vert.

- [x] **2.6 Adapter chaque main `cmd/scanner-<kind>/main.go`**
  - **Notes** : Pas de gros refactor — `runtime.Run(Config{ScanKind: ..., HandlerOptions: ...})` est inchangé en signature. Le main n'a plus besoin de toucher à la DB. La configuration env (RECONAUT_API_URL / KEY) est lue par `runtime.Run` directement.
  - **Test plan** : `go test ./cmd/scanner-*/...` reste vert. Aucun `import "database/sql"` dans les fichiers main.

---

## 3. Linter anti-DB côté workers

- [x] **3.1 `scripts/check_scanner_no_db_access.sh`**
  - **Notes** : Bash linter qui grep dans `apps/scanner/internal/**.go` (hors `_test.go`) et `apps/scanner/cmd/**.go` les patterns interdits : `import "database/sql"`, `github.com/jackc/pgx`, `github.com/lib/pq`, `RECONAUT_DATABASE_URL`. Exit ≠ 0 sur match.
  - **Test plan** : `_test.sh` jumeau qui (a) confirme exit 0 sur HEAD propre ; (b) injecte volontairement `import "database/sql"` dans un fichier prod → exit ≠ 0 ; (c) revert + exit 0.

- [x] **3.2 Wired dans `.github/workflows/ci.yml`**
  - **Notes** : Ajouter `- run: bash scripts/check_scanner_no_db_access.sh` + son `_test.sh` dans le job stack-lint, à côté des autres linters anti-* (no-billing, no-mcp-stdio, etc.).
  - **Test plan** : Run local des deux scripts → vert.

---

## 4. Update audit licences Go

- [x] **4.1 Mettre à jour `scripts/check_scanner_deps_licenses.sh`**
  - **Notes** : Retirer pgx et go-sqlmock de l'allowlist (et leurs transitives pgpassfile, pgservicefile, puddle, x/text si plus utilisées). L'allowlist post-cleanup ne contient plus que `miekg/dns` + transitives `x/crypto`, `x/mod`, `x/net`, `x/sync`, `x/sys`, `x/term`, `x/text`, `x/tools`.
  - **Test plan** : `bash scripts/check_scanner_deps_licenses.sh` exit 0 après `go mod tidy`. Le `_test.sh` reste vert.

---

## 5. Configuration : Helm + docker-compose

- [x] **5.1 Helm chart : pods scanner sans Secret DB**
  - **Notes** : `deploy/helm/reconaut/templates/scanner-*.yaml` (ou `Deployment.yaml` partagé) — retirer `valueFrom.secretKeyRef.name: reconaut-db-credentials` pour les pods scanner ; ajouter `RECONAUT_API_URL` (depuis values.yaml) et `RECONAUT_API_KEY` (depuis un nouveau Secret `reconaut-worker-api-key`). La NetworkPolicy `scanner-egress` peut maintenant restreindre à `api-svc:8080` (ou 443) + l'inventaire cibles.
  - **Test plan** : `helm template ...` ne montre plus de `RECONAUT_DATABASE_URL` dans les manifests scanner. `helm template ...` montre `RECONAUT_API_URL` + `RECONAUT_API_KEY`. Test `check_helm_chart.sh` reste vert.

- [x] **5.2 docker-compose : drop dépendance Postgres pour scanner-***
  - **Notes** : `deploy/docker-compose/docker-compose.yml` — retirer `depends_on: [postgres]` et `RECONAUT_DATABASE_URL` des services `scanner-*`. Ajouter `RECONAUT_API_URL=http://api:3000` et `RECONAUT_API_KEY=${RECONAUT_WORKER_API_KEY}` (lue depuis `.env`).
  - **Test plan** : `docker compose config` parse sans erreur. `grep -i "DATABASE_URL" docker-compose.yml | grep scanner` retourne 0 résultat.

---

## 6. Documentation

- [x] **6.1 `docs/architecture/scan-frontier.md`**
  - **Notes** : Section "Principes intangibles" — actualiser le point 1 (la sortance Rails vers le worker passe désormais par MCP, plus juste par la file Postgres). Ajouter un point sur l'architecture remote-friendly (workers déployables n'importe où avec HTTPS outbound).
  - **Test plan** : `grep -i "MCP\|remote\|worker:claim" docs/architecture/scan-frontier.md` ≥ 1 match.

- [x] **6.2 `docs/operating/deployment-helm.md`** et **`deployment-docker-compose.md`**
  - **Notes** : Documenter le nouveau modèle : workers configurés via `RECONAUT_API_URL` + `RECONAUT_API_KEY` ; comment créer une clé API de worker avec scopes ; recommandations NetworkPolicy.
  - **Test plan** : `grep -i "RECONAUT_API_KEY\|worker:claim" docs/operating/deployment-helm.md` ≥ 1 match.

- [x] **6.3 Nouvelle doc `docs/architecture/remote-scanners.md`**
  - **Notes** : Doc dédiée qui explique le pattern remote scanners : pourquoi, comment, exemples de topologie (DMZ, client-side, edge geo), sécurité (clé API scopée, audit), tradeoffs (single point of failure Rails, scope check seulement côté Rails). Cf. `init-reconaut-platform §2.5` et le présent change.
  - **Test plan** : la doc référence le présent change ; `bash scripts/check_doc_links.sh` reste vert ; mkdocs.yml ajoute l'entrée nav.

- [x] **6.4 Update mkdocs.yml**
  - **Notes** : Ajouter `Remote scanners: architecture/remote-scanners.md` dans la section Architecture du nav.
  - **Test plan** : `mkdocs build --strict` reste vert.

---

## 7. Archive de `add-scanner-pgx-driver`

- [x] **7.1 Archive `openspec/changes/add-scanner-pgx-driver/` → `openspec/archive/`**
  - **Notes** : Le change précédent est superseded par celui-ci. Une fois ce change-ci implémenté ET archivé, le précédent devient historique : son code (pgx blank import, results.SQLStore) est mort. On l'archive avec un README.md court qui pointe vers `remote-scanner-agents` comme successeur.
  - **Test plan** : `ls openspec/changes/add-scanner-pgx-driver/` retourne "No such file or directory" ; `ls openspec/archive/add-scanner-pgx-driver/` montre les fichiers.

---

## 8. Acceptance pour le change dans son ensemble

- [x] **8.1 Tests Go automatisés**
  - `cd apps/scanner && go test ./...` vert. Inclut les nouveaux tests `internal/agentclient/`, `internal/runtime/` (mis à jour). Aucun test ne référence plus pgx/sqlmock.

- [x] **8.2 Tests Ruby automatisés**
  - `cd apps/api && bundle exec rspec` vert. Inclut les nouveaux specs : `claim_job_spec.rb`, `submit_result_spec.rb`, `fail_job_spec.rb`, `lease_release_job_spec.rb`, `scanner_tools_spec.rb` (request spec).

- [x] **8.3 Linters CI**
  - `bash scripts/check_scanner_no_db_access.sh` vert. `bash scripts/check_scanner_deps_licenses.sh` vert (allowlist allégée). `bash scripts/check_doc_links.sh` vert. `bash scripts/check_helm_chart.sh` vert.

- [x] **8.4 E2E manuel documenté**
  - Procédure dans `docs/operating/deployment-docker-compose.md` :
    1. `docker compose up postgres api` ;
    2. Créer une clé API worker via `reconautctl agent-keys create --scopes worker:claim,worker:submit --label "test"` ;
    3. Lancer un worker `scanner-dns_records` avec `RECONAUT_API_URL=http://localhost:3000` + `RECONAUT_API_KEY=<clé>` (sur la machine hôte, sans accès Postgres) ;
    4. Enqueue un job via `reconautctl scan request --kind dns_records --target example.fr` ;
    5. Vérifier que `scan_results` contient le résultat (via psql ou `reconautctl scan results --kind dns_records`).

- [x] **8.5 Aucune régression**
  - Toute la suite Go + Ruby reste verte. Les changes archivés (init-reconaut-platform, add-ssh-probe, add-rdp-probe, add-http-probe, etc.) restent fonctionnels — leurs sondeurs sont juste invoqués par un handler qui reçoit ses jobs via MCP au lieu de SQL.

- [x] **8.6 Audit dépendances Go**
  - `go mod tidy` ne montre que des suppressions par rapport au commit précédent (pgx, sqlmock, et leurs transitives retirées). Pas de nouvelle dep externe ajoutée par ce change — `net/http` + `encoding/json` stdlib suffisent pour `agentclient`.
