# Change : remote-scanner-agents

## Pourquoi

Aujourd'hui les binaires `scanner-<kind>` ont besoin de **deux accès réseau** vers le cœur Reconaut :

1. **Postgres** (port 5432, creds DB) — pour claim sur `good_jobs` et insérer dans `scan_results`.
2. *(rien d'autre — c'est tout pour les workers ; ils n'appellent jamais Rails)*.

Cette dépendance DB **interdit** des topologies pourtant légitimes pour un outil d'ASM :

- **Workers en DMZ** ou dans un autre VPC qui n'a pas de route vers Postgres.
- **Workers chez le client** (scanner depuis l'intérieur du périmètre client) — donner les creds Postgres de Reconaut à un tiers est inacceptable.
- **Workers edge géographiquement diversifiés** (scanner depuis plusieurs IPs publiques pour ne pas dépendre d'une seule géolocalisation).
- **Workers air-gapped** côté infra Rails — la seule sortie permise est HTTPS vers Rails, pas du SQL vers la DB.

Le change `add-scanner-pgx-driver` qu'on vient de livrer répond AU CONTRAIRE : il a câblé la DB directement dans les workers. C'est l'inverse du besoin. **Ce change-ci pivote** pour faire des workers des **clients MCP comme les autres** :

- Le worker dialogue UNIQUEMENT avec Rails via HTTPS (les MCP HTTP+SSE existants).
- Le worker authentifie avec une clé API scopée (`worker:claim`, `worker:submit`).
- Le worker n'a JAMAIS vu Postgres ; Rails reste source unique de vérité.
- Le worker peut tourner n'importe où avec un outbound HTTPS — DMZ, NAT, infra client, edge.

C'est aussi cohérent avec le mantra `mcp-as-primary-entrypoint` : tout passe par MCP, y compris le canal de coordination des workers.

## Ce qui change

### Côté Rails (`apps/api`)

1. **3 nouveaux tools MCP** dans `app/lib/mcp/core_tools.rb` :

   - **`claim_scan_job`** : un worker réclame le prochain job de sa queue.
     - Params : `{ queue: "scan:<kind>", worker_id: "string", lease_seconds?: int }`
     - Scope requis : `worker:claim`
     - Comportement : `SELECT ... FOR UPDATE SKIP LOCKED LIMIT 1` sur `good_jobs` filtré par `queue_name`, set `performed_at = NOW()`, retourne `{ job: {id, params}, lease_until: <RFC3339> }` ou `{ empty: true }` si la file est vide.
     - **Garde scope** : Rails vérifie que `target` du job est dans le scope actif avant de hand-out (défense en profondeur — Rails déjà vérifié à enqueue, mais le scope peut avoir été révoqué entre temps). Si hors scope, Rails marque le job `finished_at + error="out-of-scope"` et retourne `{ empty: true }` (next call essaiera un autre job).

   - **`submit_scan_result`** : le worker remonte le résultat.
     - Params : `{ job_id: "uuid", idempotency_key: "string", scan_kind, target_kind, target_value, status, observed_at: <RFC3339> }`
     - Scope requis : `worker:submit`
     - Comportement : `INSERT INTO scan_results ... ON CONFLICT (idempotency_key) DO NOTHING` + `UPDATE good_jobs SET finished_at = NOW() WHERE id = $1`.

   - **`fail_scan_job`** : le worker remonte une erreur (le job ne sera pas retry automatiquement en v1 — laissé à un futur change).
     - Params : `{ job_id: "uuid", error: "string" }`
     - Scope requis : `worker:submit`
     - Comportement : `UPDATE good_jobs SET finished_at = NOW(), error = $2`.

2. **2 nouveaux scopes** ajoutés à `ScopeRegistry` :
   - `worker:claim` — permet d'appeler `claim_scan_job`.
   - `worker:submit` — permet d'appeler `submit_scan_result` et `fail_scan_job`.

3. **Recurring job de "lease release"** (côté GoodJob recurring) : toutes les 60 s, re-queue les jobs dont le lease a expiré (`performed_at < NOW() - INTERVAL '5 minutes' AND finished_at IS NULL`) en remettant `performed_at = NULL`. Évite qu'un worker qui crashe ne bloque indéfiniment un job.

4. **Aucune migration de schéma** — on réutilise les colonnes existantes de `good_jobs` (`performed_at`, `finished_at`, `error`). La table `scan_results` créée par `add-scanner-pgx-driver` est conservée.

### Côté Go (`apps/scanner`)

5. **Drop des SQL stores** :
   - `internal/results/sql.go` + `sql_test.go` : **supprimés** (workers n'écrivent plus en SQL).
   - `internal/goodjob/sql.go` : **supprimé** (workers ne claimnent plus en SQL).
   - `internal/runtime/wireStores` : ne câble plus de DB ; le seul mode reste l'in-memory pour `--dry-run`, et un nouveau mode HTTP.

6. **Drop des dépendances pgx + go-sqlmock** :
   - `github.com/jackc/pgx/v5` (+ transitives `pgpassfile`, `pgservicefile`, `puddle`) : retirées.
   - `github.com/DATA-DOG/go-sqlmock` : retirée.
   - `golang.org/x/text` (devenu inutile sans pgx) : retirée si vraiment inutile (sinon laissée indirect via x/net).

7. **Nouveau package `internal/agentclient/`** : client HTTP minimal qui implémente :
   - `Claim(ctx, queue, workerID) (*Job, error)` — POST `/mcp/tools/claim_scan_job`.
   - `Submit(ctx, jobID, result) error` — POST `/mcp/tools/submit_scan_result`.
   - `Fail(ctx, jobID, err) error` — POST `/mcp/tools/fail_scan_job`.
   - Auth : header `Authorization: Bearer <RECONAUT_API_KEY>`.
   - Body : JSON-RPC-ish (le format MCP HTTP existant ; même squelette que `reconautctl`).

8. **`runtime.Run` boucle de claim refactorée** : au lieu de `goodjob.Loop(ctx, sqlStore, handler, ...)`, on a `agentLoop(ctx, agentClient, handler, ...)` qui :
   - `Claim()` → si `empty:true`, sleep `idle-backoff` (défaut 1 s).
   - Sinon, exécute `handler(ctx, job)` ; sur succès, `Submit()` ; sur erreur, `Fail()`.

9. **Configuration env workers** :
   - `RECONAUT_API_URL` (par ex. `https://reconaut.example.com`) — OBLIGATOIRE.
   - `RECONAUT_API_KEY` — OBLIGATOIRE.
   - `RECONAUT_DATABASE_URL` — **SUPPRIMÉE** (workers ne l'utilisent plus du tout).
   - `RECONAUT_WORKER_ID` (par ex. `worker-edge-fra1-01`) — optionnel, défaut `hostname + pid`.
   - `RECONAUT_API_TLS_INSECURE` — pour dev local avec self-signed.

### Côté TUI / opérateur

10. **`reconautctl scope` ne change pas**.
11. **Nouveau `reconautctl agent-keys create --scopes worker:claim,worker:submit --label "edge-fra1"`** (optionnel — peut aussi se faire via MCP `add_scope` patterns existants).

### Déploiement

12. **Helm chart** : les pods `scanner-<kind>` n'ont plus besoin du Secret DB ; ils ont besoin de l'URL Rails + d'un Secret API key. NetworkPolicy peut maintenant restreindre l'egress des workers à `api-svc:443` uniquement.
13. **docker-compose** : idem — `scanner-*` n'ont plus la dépendance Postgres, juste un `depends_on: [api]`.

## Contraintes

- **Workers n'ont JAMAIS d'accès Postgres**. Ni en config, ni en runtime, ni en fallback. Un linter (cf. `scripts/check_scanner_no_db_access.sh`) vérifie qu'aucun import `database/sql` ni `pgx` ne survit dans `apps/scanner/`.
- **MCP HTTP+SSE reste le SEUL transport.** Pas de WebSocket dédié, pas de gRPC. Réutilise l'infrastructure HTTP+SSE existante (TLS posture, scopes, audit, allowlist REST).
- **Postgres reste source unique de vérité.** `good_jobs` et `scan_results` sont écrits exclusivement par Rails ; le worker ne fait que des appels MCP read+side-effect.
- **Idempotence préservée.** L'`idempotency_key` reste portée par le job ; `submit_scan_result` fait toujours `ON CONFLICT DO NOTHING` côté Rails — un worker qui re-submit le même job ne crée pas de doublon.
- **At-least-once garanti.** Si un worker crashe entre `Claim` et `Submit`, le lease expire et le job est re-claimable. Si un worker `Submit` deux fois (réseau qui hoquette), l'idempotency_key protège.
- **TLS posture du worker héritée de Rails.** `Mcp::TlsPosture.required?` reste le pivot ; le worker honore `RECONAUT_API_TLS_INSECURE=true` uniquement en dev.
- **Audit côté Rails.** Chaque `claim_scan_job` / `submit_scan_result` / `fail_scan_job` produit une ligne d'audit (caller_id = clé API du worker), traçabilité totale.
- **Pas de couplage scope-checker côté Go.** Le worker n'a plus accès à la table `scan_scope_entries`. Rails fait la garde au moment du claim ; le worker fait confiance au job retourné. Tradeoff documenté : si le scope est révoqué entre claim et probe (fenêtre ≤ lease 5 min), le probe peut atterrir. Acceptable car (a) Rails vérifie déjà à enqueue, (b) Rails vérifie à claim, (c) la fenêtre est courte.
- **Pas de nouvelle dépendance Go runtime.** `net/http` stdlib + `encoding/json` stdlib suffisent pour le client.

## Non-objectifs (hors scope de ce change)

- **Retry automatique côté Rails sur `fail_scan_job`.** Pour la v1, un job qui fail est marqué et c'est tout. Un futur `add-scan-retry-policy` gérera retry + backoff.
- **Streaming des résultats partiels** via SSE pendant un long scan. Reste à `submit` une seule fois en fin de probe.
- **Authentification mTLS** pour les workers. La clé API + TLS serveur suffit en v1. mTLS reste un upgrade possible (`add-worker-mtls`).
- **Worker pool elastic auto-scaling.** Le change n'introduit pas de découverte automatique de workers — c'est l'opérateur qui les déploie. Un futur `add-worker-discovery` pourrait ajouter un registre.
- **TUI dédiée pour gérer les agents.** Pas d'écran `reconautctl agents list` en v1.
- **Tableau de bord `worker_heartbeats`.** Pas d'introspection runtime "qui est connecté" — peut être déduit de l'audit log. Différé à `add-worker-observability`.
- **Suppression de la table `good_jobs`.** Toujours utilisée par Rails (GoodJob gem) pour la file. Seul l'accès direct depuis le worker Go est retiré.
- **Suppression de la table `scan_results`.** Conservée — c'est juste Rails qui écrit dedans désormais via `submit_scan_result`, pas le worker en SQL direct.

## Décisions prises

1. **Réutilise les colonnes `good_jobs` existantes** (`performed_at` comme "claimed_at", `finished_at` comme "done", `error` pour fail). Pas de migration de schéma — plus simple, moins de surface.
2. **Lease implicite via `performed_at + 5 min`**. Pas de colonne `lease_until` dédiée. Un recurring job remet `performed_at = NULL` après timeout. Suffisant pour la v1.
3. **Short polling avec `idle-backoff` (défaut 1 s)**, pas long polling. Long polling tient un thread Puma ouvert N secondes par worker — devient un goulot avec 10+ workers. Short polling = quelques req/s/worker, négligeable pour Puma.
4. **2 scopes (`worker:claim` + `worker:submit`) plutôt que 1**. Permet (par ex.) un worker "audit-only" qui claim mais ne submit pas — utile pour debug, dry-run, traçage de queue.
5. **Pas de gRPC, pas de WebSocket**. JSON-over-HTTPS via les MCP tools existants. Une seule façon de parler à Rails — moins de surface, audit unifié, TLS unifié.
6. **`agentclient` minimal, stdlib uniquement**. `net/http` + `encoding/json`. Pas de `go-resty`, pas de `sling`, pas d'OpenAPI client généré. ~200 LOC.
7. **Le change SUPPRIME la majeure partie du précédent `add-scanner-pgx-driver`.** Transparent : on l'archive `add-scanner-pgx-driver` après ce change car son SQLStore et son wireup pgx sont obsolètes. Ce qui reste vivant de `add-scanner-pgx-driver` : la table `scan_results` (utile au design final) et la migration associée.
8. **Garde de scope côté Rails au claim, pas côté worker**. Workers n'ont plus de scope-checker. Petite régression de défense en profondeur, mais simplification massive (workers ne consultent plus la DB).

## Différé (non bloquant, parqué pour plus tard)

- **`add-scan-retry-policy`** : retry automatique + backoff exponentiel côté Rails sur `fail_scan_job`.
- **`add-worker-mtls`** : mTLS optionnel pour les workers en plus de la clé API.
- **`add-worker-observability`** : table `worker_heartbeats` + tool MCP `list_workers` + intégration dans `system_doctor`.
- **`add-worker-discovery`** : registre auto + UI dans reconautctl.
- **`add-scan-streaming-results`** : SSE pour résultats partiels pendant les longs probes.
- **`add-worker-auto-scale`** : Helm HPA basé sur la profondeur de queue.
