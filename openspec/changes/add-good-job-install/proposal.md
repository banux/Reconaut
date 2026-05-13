# Change : add-good-job-install

## Pourquoi

Reconaut utilise GoodJob comme adapter ActiveJob (cf. `Gemfile` : `gem "good_job", "~> 4.0"`, et `apps/api/app/lib/reconaut/good_job_bus.rb`). Mais **la migration d'install de GoodJob n'a JAMAIS été jouée** :

```
$ RAILS_ENV=test bundle exec rails db:migrate:status
   up     20260507000001  Enable graph extensions
   up     20260507000002  Create graph labels and indexes
   up     20260507000003  Create graph roles
   up     20260508000001  Create domain model
   up     20260509000001  Create audit log
   up     20260509120001  Create auth tables
   up     20260510000001  Create embeddings table
   up     20260513000001  Create scan results
   ...                    (aucune migration good_jobs)
```

Conséquences observées et documentées :

1. **10 specs Ruby restent `pending`** sur le pattern `@skip "good_jobs absente"` — héritage de remote-scanner-agents (`claim_job_spec`, `submit_result_spec` partiel, `fail_job_spec` partiel, `lease_release_job_spec`, `scanner_tools_spec`). Ces tests valident des invariants critiques (claim transactionnel, lease release, idempotence finished_at) ; ils doivent passer pour de vrai en CI, pas être skippés.
2. **Un run e2e de `scanner-dns_records` échoue** avec `relation "good_jobs" does not exist (SQLSTATE 42P01)`. Le pivot remote-scanner-agents avait masqué ce gap (les workers ne touchent plus la DB), mais Rails lui-même attend la table dès qu'on tente d'enqueue un job via `ScanJob.perform_later`.
3. **`ScanJob.perform_later` lève à l'enqueue** en prod avec l'adapter `:good_job` configuré (cf. `Gemfile`) parce que GoodJob essaie d'INSERT dans une table inexistante.

Ce change ferme la dette en livrant les **migrations canoniques du gem GoodJob 4.x** + une **configuration d'adapter explicite** côté `config/application.rb`. C'est un change de plomberie OSS pure, zero feature business.

## Ce qui change

1. **Nouvelle migration `db/migrate/<ts>_create_good_jobs.rb`** — réplique fidèle de l'install migration que `rails generate good_job:install` aurait produit, alignée sur la version 4.x du gem :
   - Table `good_jobs` (PK uuid, queue_name, priority, serialized_params jsonb, scheduled_at, performed_at, finished_at, error, created_at, updated_at, active_job_id uuid, concurrency_key, cron_key, retried_good_job_id, cron_at, batch_id, batch_callback_id, is_discrete bool, executions_count int, job_class, error_event smallint, labels text[], locked_by_id uuid, locked_at).
   - Table `good_job_executions` (PK uuid + active_job_id + scheduled_at + performed_at + finished_at + error + serialized_params jsonb).
   - Table `good_job_processes` (PK uuid + state jsonb + lock_type smallint + locked_by_id uuid).
   - Table `good_job_settings` (PK uuid + key string + value jsonb).
   - Table `good_job_batches` (PK uuid + description + serialized_properties jsonb + on_finish + on_success + on_discard + callback_queue_name + callback_priority + enqueued_at + discarded_at + finished_at + jobs_finished_at + properties_callback_at + jobs_succeeded_count + jobs_discarded_count).
   - Indexes : sur `good_jobs(queue_name, scheduled_at)`, `good_jobs(cron_key, cron_at)`, `good_jobs(active_job_id)`, etc.
2. **Configuration explicite du queue adapter** dans `config/application.rb` : ajout de `config.active_job.queue_adapter = :good_job` (au lieu de `:test` par défaut hors test).
3. **`config/environments/test.rb`** garde `:test` adapter par défaut (les specs ActiveJob s'attendent à ça). Pas de changement nécessaire.
4. **Retrait du `@skip "good_jobs absente"` dans 5 specs** : les `@skip` deviennent inutiles puisque la table existe désormais. Les `it` qui dépendaient de good_jobs deviennent des tests pleins.

## Contraintes

- **Aucun nouveau gem**. GoodJob est déjà dans le Gemfile (~> 4.0) — on joue juste sa migration.
- **Aucune modification du schéma applicatif** (`hosts`, `services`, `scan_results`, etc.). Le change touche UNIQUEMENT les tables `good_job*`.
- **Idempotent** : la migration peut être jouée sur une base déjà migrée sans erreur (test `db:migrate:redo`).
- **Réversible** : `db:rollback` retire les tables proprement (les jobs en cours seraient perdus, ce qui est acceptable en migration administrée).
- **Compatible avec l'usage actuel** : `ScanJob.perform_later(payload)` continue de fonctionner. `GoodJobBus#enqueue` retourne toujours un `scan_id`.
- **Tests pleins, pas skippés**. Les specs qui dépendent de good_jobs doivent passer (pas être marquées `pending`).

## Non-objectifs (hors scope de ce change)

- **Tuner les options GoodJob** (workers count, polling interval, preserve_job_records, etc.) — laissés aux defaults du gem. Tuning différé.
- **Recurring jobs configuration** (notamment `LeaseReleaseJob` créé par remote-scanner-agents) — déjà documenté dans le code, mais le scheduling cron via `config.good_job.cron` est différé à un futur `add-good-job-cron-config` si besoin.
- **Migration de production existante** — ce change est zero-data : la table good_jobs n'existait pas en prod non plus (les workers tournaient en `--dry-run` ou n'étaient pas déployés). Aucun risque de perte de données.
- **Dashboard GoodJob Mission Control** — pas en v1.

## Décisions prises

1. **Migration manuelle plutôt qu'invocation du générateur**. Le générateur `rails generate good_job:install` aurait produit un fichier équivalent ; le copier explicitement dans `db/migrate/` (avec timestamp Reconaut) garantit la reproductibilité et reste lisible en review.
2. **Version fidèle à GoodJob 4.x**. La structure de table est celle attendue par le gem en 4.0+ — multi-tables (good_jobs, good_job_executions, etc.), pas la version v3 monolithique.
3. **Adapter explicite en prod/dev, `:test` en test**. Cohérent avec ScanJob#perform qui lève si l'adapter est `:inline` ou `:async` (cf. apps/api/app/jobs/scan_job.rb commentaire).
4. **Retirer les `@skip` qui deviennent inutiles** plutôt que de les laisser comme témoin. Les commentaires `# pattern @skip pour DB absente` restent dans les specs pour les futures tables manquantes.

## Différé (non bloquant, parqué pour plus tard)

- **`add-good-job-cron-config`** : configurer le scheduling cron de `LeaseReleaseJob` (chaque 60 s) via `config.good_job.cron` côté Rails. En v1, l'opérateur peut le déclencher manuellement.
- **`add-good-job-mission-control`** : mounter le dashboard `mission-control-jobs` derrière une auth scopée pour visualiser la file en temps réel.
- **`add-good-job-tuning`** : préfixes de queue, limites de concurrence, etc.
