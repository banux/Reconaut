# Change : add-good-job-cron-config

## Pourquoi

`remote-scanner-agents` (2026-05-13) a livré le job `LeaseReleaseJob` qui doit tourner périodiquement (60 s) pour re-queue les jobs dont le lease worker a expiré (`performed_at < NOW() - 5 min` ET `finished_at IS NULL`). C'est ce qui garantit le contrat **at-least-once** quand un worker crashe entre claim et submit.

Mais ce job N'EST PAS SCHÉDULÉ aujourd'hui. Le proposal de remote-scanner-agents disait : *"Le scheduling se fait via `config/initializers/good_job_recurring.rb` (ou `config/good_job.rb`) avec cron `* * * * *` (chaque minute). Différé à un futur `add-good-job-cron-config` si besoin."* — et `add-good-job-install` (2026-05-13) confirmait : *"Recurring jobs configuration — déjà documenté dans le code, mais le scheduling cron via `config.good_job.cron` est différé."*

**Aujourd'hui le LeaseReleaseJob est inerte** : sa classe existe, ses specs passent, mais en prod il n'est jamais déclenché. Conséquence concrète :

- **Un worker qui crashe entre claim et submit bloque le job indéfiniment** (la row `good_jobs.performed_at` reste figée, jamais re-NULL'ée). Le contrat at-least-once devient impraticable.
- **Pas d'autre mécanisme de récupération.** Sans le cron, un opérateur doit jouer manuellement `LeaseReleaseJob.perform_now` ou faire un UPDATE SQL.

Ce change ferme la dette : configuration cron via `config.good_job.cron` + execution mode `:async` (GoodJob tourne ses workers dans le process Puma, suffisant pour un job de maintenance léger).

## Ce qui change

1. **Nouveau `config/initializers/good_job.rb`** côté Rails :
   - Configure `Rails.application.config.good_job.execution_mode = :async` en `production` et `development`. (En `test`, l'adapter reste `:test` via `config/environments/test.rb` — pas de worker GoodJob, pas de cron.)
   - Configure `config.good_job.cron` avec une entrée `lease_release` qui pointe sur `LeaseReleaseJob`, cron `* * * * *` (chaque minute), description claire.
   - Configure `config.good_job.poll_interval = 5` (secondes) — fréquence à laquelle GoodJob polle la file pour des cron jobs à exécuter. 5 s est un bon compromis (les autres jobs sont consommés par les workers Go, GoodJob ne lance que les cron internes).
   - Configure `config.good_job.preserve_job_records = false` — pas d'archive des jobs finis (différé à `add-good-job-mission-control` si besoin).

2. **Spec rspec pour vérifier la config** :
   - `spec/config/good_job_config_spec.rb` : teste que `Rails.application.config.good_job.execution_mode == :async` en environnement non-test ET que `cron` contient une entrée `lease_release` pointant sur `LeaseReleaseJob` avec un cron `* * * * *`.

3. **Documentation** :
   - `docs/operating/deployment-docker-compose.md` et `deployment-helm.md` mentionnent que GoodJob tourne en mode `:async` (workers GoodJob dans le process Puma). Pas besoin de pod / service séparé pour les jobs cron en v1.
   - `docs/architecture/remote-scanners.md` : la section "Quand un worker crashe" pointe désormais explicitement vers `LeaseReleaseJob` qui s'exécute chaque minute.

## Contraintes

- **Pas de nouvelle dépendance**. GoodJob 4.x supporte nativement `cron` config (cf. README du gem).
- **Pas de process séparé**. Mode `:async` — GoodJob tourne dans Puma. Acceptable pour la v1 car le seul cron job est `LeaseReleaseJob` (un UPDATE rapide, plafonné à toutes les minutes). Si le besoin évolue (jobs lourds, scaling horizontal), passer à `:external` sera un futur change.
- **Test env intacte**. Le queue_adapter `:test` (configuré par `add-good-job-install`) reste prioritaire en test. Aucun worker GoodJob ne tourne en test ; le LeaseReleaseJob est exercé directement par ses specs unitaires.
- **`poll_interval=5s` raisonnable**. Pas trop court (pas de hammer Postgres) ni trop long (cron exécuté ≤ 5 s après son tick théorique).
- **Idempotence**. `LeaseReleaseJob` est déjà idempotent (cf. son spec) — exécuter deux fois ne corrompt rien.
- **`preserve_job_records=false`**. Les rows good_jobs sont supprimées après finish (default GoodJob). Si l'opérateur veut un historique, c'est différé.

## Non-objectifs (hors scope de ce change)

- **GoodJob Mission Control** (dashboard /good_job) — différé à `add-good-job-mission-control`.
- **`:external` execution mode** (pod séparé qui tourne `bundle exec good_job start`) — différé. La v1 vit dans le pod api.
- **Autres cron jobs** (purge audit logs, recompute embeddings, ...) — chaque besoin futur ajoutera son entrée dans `config.good_job.cron`.
- **Métriques Prometheus** sur GoodJob (jobs in-flight, retries, etc.) — différé à `add-otel-good-job-metrics`.
- **Tuning concurrence** (`max_threads`, `queue_concurrency`) — laissés aux defaults. Évalué quand le besoin se concrétisera.

## Décisions prises

1. **`:async` mode plutôt que `:external`** pour la v1. GoodJob ne consomme PAS les jobs `scan:*` (ce sont les workers Go via remote-scanner-agents qui le font). Le seul job que GoodJob exécute est `LeaseReleaseJob` — extrêmement léger. Pas besoin d'un process séparé.
2. **`poll_interval=5s`**. Compromis entre fraîcheur du cron et coût DB. Avec un seul cron job par minute, 5 s suffit largement.
3. **`preserve_job_records=false`**. Pas d'archive en v1 ; économise de l'espace DB. Le journal d'audit (`agent_audit`) sert déjà à tracer les opérations métier (claim/submit).
4. **Cron config via `initializers/good_job.rb`** plutôt qu'un fichier YAML séparé. Cohérent avec le pattern Rails (initializers tournent au boot, pas de runtime parsing). Inspectable depuis le code.
5. **Description claire dans le cron**. La GoodJob dashboard (futur) affichera la description ; on profite pour documenter l'invariant "5 min lease release" dans le hash.

## Différé (non bloquant, parqué pour plus tard)

- **`add-good-job-mission-control`** : mounter le dashboard `mission-control-jobs` côté Rails derrière une auth scopée.
- **`add-good-job-external-mode`** : passer en mode `:external` (pod GoodJob dédié) si le profil de charge évolue (jobs lourds, multi-replica).
- **`add-good-job-purge-cron`** : cron de purge des anciens `good_jobs` finis si on ré-active `preserve_job_records`.
- **`add-otel-good-job-metrics`** : exposition Prometheus.
