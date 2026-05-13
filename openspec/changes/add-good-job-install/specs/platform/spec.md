# Spec delta : platform

## ADDED Requirements

### Requirement: Tables `good_job*` migrées et utilisables
La migration Rails `db/migrate/<ts>_create_good_jobs.rb` DOIT créer le set de tables attendu par le gem `good_job` ~> 4.0. Au minimum :

- `good_jobs` avec PK `id uuid`, colonnes `queue_name`, `priority`, `serialized_params jsonb`, `scheduled_at timestamptz`, `performed_at timestamptz`, `finished_at timestamptz`, `error text`, `created_at`, `updated_at`, `active_job_id uuid`, `concurrency_key`, `cron_key`, `retried_good_job_id`, `cron_at`, `batch_id`, `batch_callback_id`, `is_discrete bool`, `executions_count int`, `job_class`, `error_event smallint`, `labels text[]`, `locked_by_id uuid`, `locked_at timestamptz`.
- Index sur `(queue_name, scheduled_at) WHERE finished_at IS NULL`, sur `active_job_id`, sur `cron_key, cron_at`, sur `(priority, scheduled_at) WHERE finished_at IS NULL`.
- Tables `good_job_executions`, `good_job_processes`, `good_job_settings`, `good_job_batches` avec leurs PK uuid et colonnes documentées par le gem.

La migration DOIT être idempotente (rejouable sans erreur après `db:migrate:redo`) et réversible (`db:rollback` retire les tables sans `DROP CASCADE` agressif).

#### Scenario: Migration applied → tables présentes
- **GIVEN** une base `reconaut_test` propre
- **WHEN** `RAILS_ENV=test bundle exec rails db:migrate` est exécuté
- **THEN** les 5 tables `good_jobs`, `good_job_executions`, `good_job_processes`, `good_job_settings`, `good_job_batches` existent
- **AND** `ActiveRecord::Base.connection.table_exists?(:good_jobs)` retourne `true`
- **AND** un test `expect(GoodJob::Job.where(finished_at: nil).count).to be_a(Integer)` ne lève pas.

#### Scenario: INSERT direct dans good_jobs réussit
- **GIVEN** la migration appliquée
- **WHEN** un test exécute `INSERT INTO good_jobs (id, queue_name, serialized_params, created_at) VALUES (gen_random_uuid(), 'scan:test', '{}', NOW())`
- **THEN** la requête s'exécute sans erreur
- **AND** `SELECT COUNT(*) FROM good_jobs WHERE queue_name='scan:test'` retourne au moins 1.

#### Scenario: Les 10 specs qui skippaient via @skip "good_jobs absente" passent désormais pour de vrai
- **GIVEN** la migration appliquée en test DB
- **WHEN** `bundle exec rspec` est exécuté
- **THEN** les specs suivantes passent (pas de `pending`) :
  - `spec/use_cases/scanner/claim_job_spec.rb` (6 examples)
  - `spec/use_cases/scanner/fail_job_spec.rb` (1 example sur le `context "avec table good_jobs présente"`)
  - `spec/jobs/lease_release_job_spec.rb` (3 examples sur le `context "avec table good_jobs présente"`)
- **AND** le total `pending` baisse d'au moins 10 par rapport à avant la migration.

#### Scenario: ScanJob.perform_later enqueue effectivement
- **GIVEN** l'adapter ActiveJob `:good_job` configuré côté Rails
- **WHEN** un test invoque `ScanJob.perform_later({"scan_kind" => "dns_records", "target" => {...}})`
- **THEN** une ligne est insérée dans `good_jobs` avec `queue_name="scan:dns_records"`, `serialized_params` non vide, `finished_at IS NULL`
- **AND** `GoodJob::Job.where(queue_name: "scan:dns_records").count` reflète l'enqueue.

### Requirement: ActiveJob queue adapter configuré sur GoodJob en non-test
Le fichier `config/application.rb` (ou un environnement spécifique) DOIT déclarer `config.active_job.queue_adapter = :good_job` pour que l'enqueue via `perform_later` cible la table `good_jobs` plutôt que l'adapter `:async` par défaut (qui exécute inline et casse le contrat scope-driven).

L'environnement `test` PEUT conserver l'adapter `:test` (les specs `have_enqueued_job` matcher s'y attendent).

#### Scenario: adapter actif en dev/prod
- **GIVEN** `RAILS_ENV=development` (ou `production`)
- **WHEN** Rails boot
- **THEN** `ActiveJob::Base.queue_adapter.class.name` est `ActiveJob::QueueAdapters::GoodJobAdapter` (ou équivalent gem)
- **AND** un `perform_later` se traduit par une INSERT en DB, pas une exécution inline.

#### Scenario: adapter test reste :test
- **GIVEN** `RAILS_ENV=test`
- **WHEN** une spec invoque `ActiveJob::Base.queue_adapter`
- **THEN** c'est `ActiveJob::QueueAdapters::TestAdapter`
- **AND** les matchers `have_enqueued_job` fonctionnent normalement.
