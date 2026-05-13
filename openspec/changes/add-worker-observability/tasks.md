# Tâches : add-worker-observability

Checklist : workers Go émettent des heartbeats périodiques, Rails expose `list_workers` + enrichit `system_doctor`.

---

## 1. Côté Go

- [x] **1.1 Méthode `agentclient.Client.Heartbeat(ctx, scanKind, inflight)`**
  - **Notes** : Nouvelle méthode publique dans `internal/agentclient/client.go`. Construit le payload `HeartbeatV1` (worker_id depuis `c.WorkerID`, version depuis `worker.Version`, emitted_at = `time.Now().UTC().Format(time.RFC3339)`). Appelle `c.invoke(ctx, "submit_heartbeat", params)`. Retourne erreur si la requête HTTP échoue (le caller décide quoi en faire).
  - **Test plan** : Nouveau test `TestHeartbeat_HappyPath` qui valide via httptest le shape du payload reçu (worker_id, scan_kind, version, schema_version=1, inflight_jobs).

- [x] **1.2 Goroutine heartbeat dans `runtime.Run`**
  - **Notes** : Après la construction du `client`, spawn une goroutine qui `time.NewTicker(heartbeatInterval).C` et appelle `client.Heartbeat(ctx, scanKind, inflightJobsCounter())`. La goroutine s'arrête sur `<-ctx.Done()`. Échec : `log.Printf("scanner: heartbeat error: %v", err)` puis continue.
  - L'intervalle est lu depuis `RECONAUT_HEARTBEAT_INTERVAL` (secondes, défaut 30).
  - `inflightJobsCounter` peut être un simple `atomic.Int64` incrémenté/décrémenté autour de chaque `handler(ctx, job)` dans la boucle agentLoop.
  - **Test plan** : Test `TestAgentLoop_EmitsHeartbeats` — un httptest server qui compte les requêtes vers `/mcp/tools/submit_heartbeat` ; le worker tourne 2 s avec `heartbeatInterval=200ms` ; on attend ≥ 5 heartbeats reçus avec le bon worker_id.

- [x] **1.3 `RECONAUT_HEARTBEAT_INTERVAL` lu et appliqué**
  - **Notes** : Dans `runtime.Run`, parser la variable, défaut 30 s, max 600 s. Passer au lancement de la goroutine.
  - **Test plan** : Test : env var = "5" → ticker à 5 s ; env vide → 30 s ; env négatif → 30 s (défaut, log warn).

---

## 2. Côté Rails

- [x] **2.1 Étendre `packages/job-schema/heartbeat_v1.json` avec `scan_kind`**
  - **Notes** : Ajouter `scan_kind` aux `properties`, optionnel, `{ "type": "string", "maxLength": 64 }`. Pas de modification de `required`.
  - **Test plan** : `JobSchema::Registry.validate("HeartbeatV1", payload_avec_scan_kind)` retourne `[true, []]`. Sans le champ : idem (backward-compat).

- [x] **2.2 `Heartbeats::Record` + store consomme `scan_kind`**
  - **Notes** : Ajouter `scan_kind` à la Struct `Reconaut::Heartbeats::Record` (keyword arg, défaut nil). Mettre à jour `InMemoryStore#record!` pour extraire `scan_kind` depuis le payload et l'inclure dans le Record. Mettre à jour `to_h` pour exposer le champ.
  - **Test plan** : `spec/lib/reconaut/heartbeats_spec.rb` — test qui record un payload avec scan_kind, lit `latest`, vérifie `record.scan_kind == "service_fingerprint"`.

- [x] **2.3 Use case `Scanner::ListWorkers`**
  - **Notes** : Sous `app/use_cases/scanner/list_workers.rb`. Constante `Scanner::ListWorkers` (Zeitwerk-aligned). Signature : `call(recent_seconds: 300, caller_id:)`. Implémentation :
    1. `cutoff = Time.now.utc - recent_seconds`
    2. `records = heartbeat_store.list.select { |r| Time.parse(r.seen_at) >= cutoff }`
    3. Map vers `{ worker_id, scan_kind, version, inflight_jobs, seen_at, seconds_since_last_seen }`, trie DESC.
    4. Retourne `Scanner::Result.new(status: :ok, body: { workers: ... })`.
  - **Test plan** : `spec/use_cases/scanner/list_workers_spec.rb` — (a) 2 récents + 1 vieux → 2 retournés triés DESC ; (b) tout vieux → vide ; (c) tri DESC vérifié.

- [x] **2.4 Tool MCP `list_workers` enregistré**
  - **Notes** : Dans `core_tools.rb`, ajouter `ToolRegistry.register(name: "list_workers", scopes: [:"read:health"], params_schema: { recent_seconds: { type: :integer, required: false, default: 300, min: 1, max: 3600 } })`. Invoque `Scanner::ListWorkers.new(heartbeat_store: heartbeat_store).call(...)`.
  - **Test plan** : Request spec `spec/requests/mcp/list_workers_spec.rb` : (a) avec heartbeats récents → response 200 + body workers ; (b) sans → workers: [] ; (c) sans scope read:health → 403 (via clé limited).

- [x] **2.5 Enrichir `Reconaut::Doctor` avec probe `worker_heartbeats`**
  - **Notes** : Ajouter un probe `worker_heartbeats` qui :
    - count = nombre de heartbeats vus dans 5 min
    - oldest_age_s = âge du plus ancien actif (nil si count=0)
    - status: "ok" si count >= 1, "degraded" si count == 0
  - Conserver le probe existant `last_worker_heartbeat`.
  - **Test plan** : `spec/lib/reconaut/doctor_spec.rb` — étendre les specs existantes pour vérifier le nouveau probe dans le report.

---

## 3. Liste des outils MCP

- [x] **3.1 Mettre à jour `spec/requests/mcp/tools_spec.rb`**
  - **Notes** : Ajouter `list_workers` à la liste `contain_exactly` du test `liste les outils enregistres avec leurs scopes et schemas`.
  - **Test plan** : Spec passe.

---

## 4. Documentation

- [x] **4.1 `docs/architecture/remote-scanners.md`**
  - **Notes** : Ajouter une section "Heartbeat & observabilité" : workers émettent toutes les 30 s, opérateur consulte via `list_workers` ou `system_doctor`. Lien vers ce change.
  - **Test plan** : `grep -i "heartbeat" docs/architecture/remote-scanners.md` ≥ 1 match.

- [x] **4.2 `docs/operating/deployment-helm.md`**
  - **Notes** : Mentionner la nouvelle env `RECONAUT_HEARTBEAT_INTERVAL` (défaut 30 s ; recommandation prod : 30-60 s).
  - **Test plan** : `grep -i "RECONAUT_HEARTBEAT_INTERVAL" docs/operating/` ≥ 1 match.

---

## 5. Acceptance

- [x] **5.1 Tests Go**
  - `go test ./internal/agentclient/ ./internal/runtime/` vert. Nouveau test pour heartbeat goroutine.

- [x] **5.2 Tests Ruby**
  - `bundle exec rspec spec/use_cases/scanner/list_workers_spec.rb spec/requests/mcp/list_workers_spec.rb` vert.

- [x] **5.3 Suite complète sans régression**
  - `go test ./...` vert, `bundle exec rspec` vert.

- [x] **5.4 E2E manuel (documenté)**
  - Procédure dans `docs/architecture/remote-scanners.md` :
    1. Lancer Rails + Postgres
    2. Lancer un worker `scanner-dns_records` avec env complète (incluant `RECONAUT_HEARTBEAT_INTERVAL=5`)
    3. Attendre 15 s
    4. `reconautctl mcp list_workers` (ou curl direct) doit montrer le worker.
