# Change : add-worker-observability

## Pourquoi

Depuis `remote-scanner-agents` (2026-05-13), les workers `scanner-<kind>` dialoguent avec Rails via MCP HTTP — Rails est seul à savoir qui se connecte. Mais aujourd'hui, **un opérateur n'a aucun moyen de voir** :

- Quels workers sont actuellement connectés à son instance ?
- Depuis quand chacun a-t-il fait son dernier appel ?
- Quel `scan_kind` chacun couvre ?
- Quelle version du binaire scanner chacun fait tourner ?
- Combien y en a-t-il, et lequel est éventuellement bloqué (silence prolongé) ?

Trois trous concrets :

1. **`submit_heartbeat` est livré mais personne ne l'appelle.** Le tool MCP `submit_heartbeat` (init-reconaut-platform §6 + `Reconaut::Heartbeats::InMemoryStore`) accepte des payloads `HeartbeatV1` depuis 2026-05-08, mais **aucun binaire Go n'en émet**. Le `Reconaut::Doctor` probe `last_worker_heartbeat` retourne toujours `null`.
2. **Aucun tool pour lister les workers.** L'opérateur peut envoyer un heartbeat, mais ne peut pas demander à Rails « quels workers as-tu vu récemment ? ». Les seules traces sont dans `agent_audit` (log des appels MCP) — pas exploitable opérationnellement.
3. **Pas de probe d'inactivité.** Si tous les workers crashent, Rails ne déclenche aucune alerte ; l'opérateur découvre le problème en voyant que `request_scan` n'a pas de résultat.

Ce change ferme les trois trous : (a) le worker Go émet un heartbeat toutes les 30 s, (b) un nouveau tool MCP `list_workers` retourne les workers actifs (heartbeat < 5 min), (c) `system_doctor` enrichit son probe avec le compte de workers actifs et signale `degraded` quand il tombe à 0.

## Ce qui change

### Côté Go (`apps/scanner`)

1. **Nouvelle méthode `agentclient.Client.Heartbeat(ctx, scanKind, inflight)`** qui appelle `POST /mcp/tools/submit_heartbeat` avec un payload `HeartbeatV1` :
   ```json
   {
     "schema_version": 1,
     "worker_id": "<RECONAUT_WORKER_ID>",
     "emitted_at": "<RFC3339>",
     "inflight_jobs": <int>,
     "version": "<scanner-worker --version>"
   }
   ```

2. **`runtime.Run` lance une goroutine heartbeat** qui appelle `Heartbeat` toutes les `RECONAUT_HEARTBEAT_INTERVAL` (défaut 30 s). Au shutdown (SIGTERM), la goroutine est annulée via le contexte parent. Échec d'un heartbeat n'interrompt pas la boucle de claim (best-effort) — il est loggé en `Warn`.

### Côté Rails (`apps/api`)

3. **Use case `Scanner::ListWorkers`** (sous `app/use_cases/scanner/list_workers.rb`) qui lit `Reconaut::Heartbeats` et retourne les workers vus récemment :
   - Param : `recent_seconds` (défaut 300 = 5 min).
   - Retour : `{ workers: [{ worker_id, scan_kind, version, inflight_jobs, seen_at, seconds_since_last_seen }, ...] }`.
   - Trie par `seen_at` DESC.

4. **Nouveau tool MCP `list_workers`** dans `core_tools.rb` :
   - Scope : `read:health`.
   - Params : `recent_seconds` (optionnel, défaut 300, max 3600).
   - Délègue à `Scanner::ListWorkers.call`.

5. **`Reconaut::Heartbeats::InMemoryStore.record!` enrichi** pour accepter `scan_kind` (champ optionnel du `HeartbeatV1` payload — à ajouter au schema).

6. **`packages/job-schema/heartbeat_v1.json` étendu** :
   - Nouveau champ `scan_kind` (optionnel, string, max 64). Permet à un worker `scanner-dns_records` de se déclarer comme tel.

7. **`Reconaut::Doctor` enrichi** : probe `worker_heartbeats` (en plus du `last_worker_heartbeat` existant) qui retourne :
   - `active_workers_count` : nombre de workers vus dans les 5 dernières minutes.
   - `oldest_active_worker_age_s` : ancienneté du heartbeat le plus ancien parmi les actifs.
   - Status `degraded` si `active_workers_count == 0` (aucun worker connecté).

## Contraintes

- **Heartbeat best-effort, non bloquant**. Un échec HTTP du heartbeat NE DOIT PAS faire échouer la boucle de claim. Il est loggé en `Warn` et retenté au tick suivant.
- **Goroutine heartbeat respecte le ctx**. Au shutdown (SIGTERM), la goroutine s'arrête proprement via `<-ctx.Done()`.
- **Pas de nouvelle dépendance Go**. Le payload est un `map[string]any` JSON-marshalé, comme le reste du `agentclient`.
- **In-memory store conservé** (différé : persistance DB). Acceptable pour la v1 single-instance : les heartbeats sont rapidement remis à jour (30 s) et leur perte au restart n'est pas critique.
- **Pas de notification push** quand un worker disparaît. L'opérateur consulte via `system_doctor` ou `list_workers`. Push différé.
- **Pas d'authentification spécifique** : les workers utilisent la même clé API que pour claim/submit. Le scope `write:heartbeats` est déjà dans `DEFAULT_SCOPES`.
- **Pas de retention** des heartbeats anciens. Le store écrase `worker_id` → dernier heartbeat. Pas d'historique en v1.

## Non-objectifs (hors scope de ce change)

- **Persistance DB du store heartbeats** — différé. La table `worker_heartbeats` est un sujet à part (rotation, hypertable, index).
- **Historique / time-series des heartbeats** — différé. On garde seulement le dernier par worker_id.
- **Alerting / notification** quand un worker tombe — différé à un futur `add-worker-alerting` (intégration OTEL ou webhook).
- **Métriques Prometheus** dédiées (`reconaut_workers_active_total`, etc.) — différé à `add-otel-worker-metrics`.
- **Multi-instance Rails** : si Rails est scale-out en plusieurs replicas, chaque replica a son propre store in-memory. Cohérence éventuelle uniquement quand le store sera DB-backed.
- **Tableau de bord TUI** : pas de `reconautctl workers list` en v1. L'opérateur appelle `list_workers` via MCP directement (ou via le doctor).

## Décisions prises

1. **Réutilise l'infrastructure existante `submit_heartbeat` + `Heartbeats::InMemoryStore`** au lieu de créer une parallèle. Le tool était dormant ; on l'active.
2. **Intervalle 30 s par défaut**. Compromis entre fraîcheur (un worker mort est détecté en < 5 min via le filtre `recent_seconds`) et coût HTTP (∼120 req/h/worker, négligeable).
3. **Goroutine séparée plutôt qu'inline avec claim**. Le claim peut idle pendant `idleBackoff` longtemps si la file est vide — sans goroutine dédiée, le heartbeat serait raté. Goroutine indépendante = ticks réguliers garantis.
4. **Worker_id de l'heartbeat = `RECONAUT_WORKER_ID`** (déjà défini par `remote-scanner-agents`). Pas de nouveau mécanisme.
5. **`scan_kind` ajouté au HeartbeatV1 schema** (champ optionnel — backward-compatible). Permet à `list_workers` de filtrer par kind si besoin.
6. **`system_doctor` Status `degraded` si 0 workers** plutôt que `down`. Rails fonctionne (MCP répond), juste aucun scan ne s'exécute — c'est une dégradation, pas une panne totale.

## Différé (non bloquant, parqué pour plus tard)

- **`add-worker-heartbeats-persist`** : persister les heartbeats dans une table Postgres (survie au restart Rails).
- **`add-worker-alerting`** : webhook ou OTEL alert quand un worker tombe.
- **`add-otel-worker-metrics`** : compteurs Prometheus `reconaut_workers_active_total` exposés sur `/metrics`.
- **`add-reconautctl-workers`** : commande TUI `reconautctl workers list` qui appelle `list_workers` et l'affiche en tableau.
- **`add-worker-history`** : time-series TimescaleDB des heartbeats pour debug post-mortem.
