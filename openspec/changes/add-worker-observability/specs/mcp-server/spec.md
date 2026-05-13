# Spec delta : mcp-server

## ADDED Requirements

### Requirement: MCP Tool `list_workers`
Le serveur MCP DOIT exposer un tool `list_workers` qui retourne la liste des workers ayant émis un heartbeat récemment.

- **Scope requis** : `read:health`.
- **Params** :
  - `recent_seconds` (int, optionnel, défaut 300, min 1, max 3600) : fenêtre de fraîcheur. Seuls les heartbeats dont `seen_at >= NOW() - recent_seconds` sont retournés.
- **Comportement** : délègue au use case `Scanner::ListWorkers` qui interroge `Reconaut::Heartbeats` (currently `InMemoryStore`).
- **Retour** : `{ workers: [{ worker_id, scan_kind, version, inflight_jobs, seen_at, seconds_since_last_seen }, ...] }`. Trié par `seen_at` DESC.
- **Audit** : `template_id="mcp:list_workers"`, `caller_id`.

#### Scenario: list_workers retourne les workers actifs récents
- **GIVEN** 3 workers ont envoyé `submit_heartbeat` dans les 5 dernières minutes
- **WHEN** un opérateur appelle `POST /mcp/tools/list_workers` (scope `read:health`)
- **THEN** la réponse est `{ workers: [3 entries ...] }`, triées par `seen_at` DESC
- **AND** chaque entrée contient `worker_id`, `seen_at`, `seconds_since_last_seen`.

#### Scenario: workers anciens filtrés
- **GIVEN** un worker A vu il y a 10 secondes, un worker B vu il y a 600 secondes
- **WHEN** l'opérateur appelle `list_workers(recent_seconds: 300)`
- **THEN** la réponse contient UNIQUEMENT le worker A (B est trop ancien).

#### Scenario: scope manquant → 403
- **GIVEN** une clé API qui n'a PAS `read:health`
- **WHEN** elle appelle `list_workers`
- **THEN** la réponse est `403` avec `error: "missing_scope: read:health"`.

### Requirement: Probe `worker_heartbeats` enrichi dans system_doctor
Le report `system_doctor` DOIT inclure un probe `worker_heartbeats` qui retourne :

- `active_workers_count` : nombre de workers vus dans les 5 dernières minutes.
- `oldest_active_worker_age_s` : âge en secondes du heartbeat le plus ancien parmi les actifs (utile pour détecter un worker silencieux).
- Status sémantique :
  - `ok` si `active_workers_count >= 1`.
  - `degraded` si `active_workers_count == 0` (aucun worker connecté ; les scans ne s'exécuteront pas).

Le probe `last_worker_heartbeat` existant est CONSERVÉ (compatibilité avec les outils qui le consomment déjà).

#### Scenario: doctor signale degraded sans worker
- **GIVEN** aucun heartbeat reçu dans les 5 dernières minutes
- **WHEN** un opérateur appelle `system_doctor`
- **THEN** le report contient un probe `worker_heartbeats` avec `status: "degraded"` et `active_workers_count: 0`
- **AND** le champ `oldest_active_worker_age_s` peut être `null`.

#### Scenario: doctor signale ok avec workers actifs
- **GIVEN** 2 workers ont envoyé un heartbeat dans la dernière minute
- **WHEN** le doctor est appelé
- **THEN** le probe contient `status: "ok"`, `active_workers_count: 2`, `oldest_active_worker_age_s` ≤ 60.
