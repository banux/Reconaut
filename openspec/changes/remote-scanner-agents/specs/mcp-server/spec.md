# Spec delta : mcp-server

## ADDED Requirements

### Requirement: MCP Tool `claim_scan_job`
Le serveur MCP DOIT exposer un tool `claim_scan_job` qui permet à un worker distant de réclamer le prochain job d'une queue donnée. Le tool DOIT :

- **Scope requis** : `worker:claim`.
- **Params** :
  - `queue` (string, requis) : nom de la queue, ex. `"scan:dns_records"`.
  - `worker_id` (string, requis, max 128 chars) : identifiant du worker pour audit.
  - `lease_seconds` (int, optionnel, défaut 300, max 1800) : durée du lease.
- **Comportement** :
  - Ouvre une transaction Postgres, exécute `SELECT ... FROM good_jobs WHERE queue_name=$1 AND finished_at IS NULL AND (performed_at IS NULL OR performed_at < NOW() - INTERVAL '<lease>' SECONDS) FOR UPDATE SKIP LOCKED LIMIT 1`.
  - Si aucune row : retourne `{ empty: true }`.
  - Sinon : extrait `target` du payload, **vérifie le scope actif** (`scan_scope_entries`) ; si le target est hors scope, marque le job `finished_at = NOW(), error = 'out-of-scope'` et retourne `{ empty: true }` (le call suivant essaiera une autre row).
  - Si scope OK : set `performed_at = NOW()`, commit, et retourne `{ empty: false, job: { id, params, lease_until } }` où `lease_until = NOW() + lease_seconds`.
- **Audit** : chaque appel produit une ligne `agent_audit` avec `template_id="/scan/claim"`, `caller_id` = clé API du worker, `params_normalized = {queue, worker_id}`.

#### Scenario: claim d'un job pending → retourne job + set performed_at
- **GIVEN** un job `j-1` dans `good_jobs` avec `queue_name="scan:dns_records"`, `performed_at IS NULL`, `finished_at IS NULL`, et son `target` dans le scope actif
- **WHEN** un worker appelle `claim_scan_job(queue="scan:dns_records", worker_id="w-1")` avec une clé API scopée `worker:claim`
- **THEN** la réponse est `{ empty: false, job: { id: "j-1", params: {...}, lease_until: "<RFC3339>" } }`
- **AND** côté DB, `good_jobs[j-1].performed_at IS NOT NULL`
- **AND** une ligne d'audit est créée avec `template_id="/scan/claim"`

#### Scenario: file vide → retourne empty:true
- **GIVEN** aucun job pending sur la queue
- **WHEN** un worker appelle `claim_scan_job`
- **THEN** la réponse est `{ empty: true }`
- **AND** aucune ligne `good_jobs` n'est mutée

#### Scenario: target hors scope au moment du claim → job marqué fail, retourne empty
- **GIVEN** un job `j-2` dont le target est hors scope (le scope a été révoqué après enqueue)
- **WHEN** un worker appelle `claim_scan_job`
- **THEN** la réponse est `{ empty: true }`
- **AND** côté DB, `good_jobs[j-2].finished_at IS NOT NULL` et `good_jobs[j-2].error = "out-of-scope"`

#### Scenario: scope `worker:claim` manquant → 403
- **GIVEN** une clé API qui n'a PAS le scope `worker:claim`
- **WHEN** elle appelle `claim_scan_job`
- **THEN** Rails retourne `403 forbidden` avec `error: "missing_scope: worker:claim"`

#### Scenario: jobs avec lease expiré sont re-claimables
- **GIVEN** un job `j-3` claimé il y a 6 minutes par worker w-A qui n'a jamais submit (perdu)
- **WHEN** un autre worker w-B appelle `claim_scan_job` avec `lease_seconds=300`
- **THEN** la réponse contient `j-3` (le filtre `performed_at < NOW() - 300s` le considère récup'able)
- **AND** `performed_at` est mis à jour à NOW()

### Requirement: MCP Tool `submit_scan_result`
Le serveur MCP DOIT exposer un tool `submit_scan_result` qui permet à un worker de remonter le résultat d'un job. Le tool DOIT :

- **Scope requis** : `worker:submit`.
- **Params** :
  - `job_id` (string, requis) : id retourné par `claim_scan_job`.
  - `idempotency_key` (string, requis, min 1, max 128) : clé de déduplication.
  - `scan_kind` (string, requis).
  - `target_kind` (string, requis).
  - `target_value` (string, requis).
  - `status` (string, requis) : résultat sérialisé (JSON ou string libre).
  - `observed_at` (string, requis, RFC3339).
- **Comportement** :
  - Exécute en transaction :
    - `INSERT INTO scan_results (idempotency_key, scan_kind, target_kind, target_value, status, observed_at) VALUES (...) ON CONFLICT (idempotency_key) DO NOTHING`
    - `UPDATE good_jobs SET finished_at = NOW() WHERE id = $1 AND finished_at IS NULL`
  - Retourne `{ ok: true }` même si l'idempotency_key existait déjà (idempotence côté MCP).
- **Audit** : `template_id="/scan/submit"`, `caller_id`, `params_normalized = {job_id, idempotency_key, scan_kind, target_kind}` (le `status` complet n'est pas auditisé pour ne pas exploser la taille).

#### Scenario: submit d'un job claim'é → scan_results + finished_at
- **GIVEN** un job j-1 dont `performed_at IS NOT NULL` et `finished_at IS NULL`
- **WHEN** un worker appelle `submit_scan_result(job_id="j-1", idempotency_key="k-1", ...)` avec scope `worker:submit`
- **THEN** la réponse est `{ ok: true }`
- **AND** `scan_results` contient une ligne avec `idempotency_key="k-1"`
- **AND** `good_jobs[j-1].finished_at IS NOT NULL`

#### Scenario: double submit (même idempotency_key) → idempotent
- **GIVEN** un job j-1 déjà submit (scan_results contient déjà k-1)
- **WHEN** un worker retry submit avec `idempotency_key="k-1"`
- **THEN** la réponse est `{ ok: true }` (pas 409 ni 4xx)
- **AND** `scan_results` contient TOUJOURS UNE seule ligne `k-1`
- **AND** `good_jobs[j-1].finished_at` n'est pas modifié (déjà set par le 1er submit)

#### Scenario: idempotency_key vide → 400
- **GIVEN** un appel `submit_scan_result(idempotency_key="", ...)`
- **WHEN** Rails reçoit
- **THEN** la réponse est `400` avec `error: "idempotency_key required"`
- **AND** aucune ligne n'est insérée

### Requirement: MCP Tool `fail_scan_job`
Le serveur MCP DOIT exposer un tool `fail_scan_job` qui permet à un worker de marquer un job comme échec terminal. **Pas de retry automatique en v1**.

- **Scope requis** : `worker:submit`.
- **Params** :
  - `job_id` (string, requis).
  - `error` (string, requis, max 1024 chars).
- **Comportement** : `UPDATE good_jobs SET finished_at = NOW(), error = $2 WHERE id = $1 AND finished_at IS NULL`. Si la row n'existe pas ou est déjà finished, retourne `{ ok: true }` quand même (idempotence).
- **Audit** : `template_id="/scan/fail"`.

#### Scenario: fail d'un job en cours → finished_at + error
- **GIVEN** un job j-2 en cours (`performed_at IS NOT NULL, finished_at IS NULL`)
- **WHEN** un worker appelle `fail_scan_job(job_id="j-2", error="dial timeout")` avec scope `worker:submit`
- **THEN** la réponse est `{ ok: true }`
- **AND** `good_jobs[j-2].finished_at IS NOT NULL` et `good_jobs[j-2].error = "dial timeout"`

### Requirement: Scopes `worker:claim` et `worker:submit` enregistrés
Les deux scopes sont enregistrés dans `Reconaut::ScopeRegistry` (ou équivalent existant) avec des descriptions explicites. Les clés API peuvent les recevoir individuellement ou les deux.

#### Scenario: création d'une clé API avec scopes worker
- **GIVEN** l'opérateur connecté en MCP avec scope `write:api_keys`
- **WHEN** il appelle `create_api_key(label="edge-fra1", scopes=["worker:claim", "worker:submit"])`
- **THEN** une clé API est créée avec ces deux scopes
- **AND** un test `Reconaut::ScopeRegistry.known?("worker:claim")` retourne true

### Requirement: Recurring job de "lease release"
Un job GoodJob recurring DOIT tourner toutes les 60 secondes et re-queue les jobs dont le lease est expiré :

```sql
UPDATE good_jobs
SET    performed_at = NULL
WHERE  finished_at IS NULL
  AND  performed_at IS NOT NULL
  AND  performed_at < NOW() - INTERVAL '5 minutes'
```

Le seuil de 5 minutes est aligné sur le lease par défaut de `claim_scan_job`.

#### Scenario: job avec performed_at > 5 min sans submit → re-queue
- **GIVEN** un job avec `performed_at = NOW() - 10 min` et `finished_at IS NULL`
- **WHEN** le recurring job lease-release tourne
- **THEN** la row est mise à jour : `performed_at = NULL`
- **AND** un prochain `claim_scan_job` peut la re-claim normalement
