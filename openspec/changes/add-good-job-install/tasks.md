# Tâches : add-good-job-install

Checklist de l'install des migrations GoodJob 4.x + configuration adapter. Chaque tâche inclut notes + test plan.

---

## 1. Migration

- [x] **1.1 Créer `db/migrate/<ts>_create_good_jobs.rb`**
  - **Notes** : Réplique fidèle de la migration `good_job:install` v4.x. 5 tables (`good_jobs`, `good_job_executions`, `good_job_processes`, `good_job_settings`, `good_job_batches`) + index. Utiliser `enable_extension :pgcrypto` si nécessaire pour `gen_random_uuid()`.
  - Approche : (a) tenter `bundle exec rails generate good_job:install` ; si refusé par sandbox, (b) écrire le fichier à la main basé sur la spec officielle du gem 4.x (présente dans `/path/to/good_job/lib/generators/good_job/install_generator.rb`).
  - **Test plan** : `RAILS_ENV=test bundle exec rails db:migrate` passe. `db:rollback` retire les tables sans erreur. `db:migrate:redo` idempotent.

- [x] **1.2 Migrer test ET development DBs**
  - **Notes** : Jouer la migration sur les 2 environnements pour que les specs ET un run e2e local fonctionnent.
  - **Test plan** : `bundle exec rails db:migrate:status` montre la nouvelle migration `up` en test et dev.

---

## 2. Configuration adapter

- [x] **2.1 `config/application.rb` : `queue_adapter = :good_job`**
  - **Notes** : Ajouter `config.active_job.queue_adapter = :good_job` dans la classe `Application` (s'applique à tous les envs sauf override). Documenter en commentaire que `:test` reste en test via `config/environments/test.rb`.
  - **Test plan** : Boot Rails en `development` → `ActiveJob::Base.queue_adapter.class.name` contient "GoodJob". Test env → "Test".

- [x] **2.2 Vérifier `config/environments/test.rb`** ne définit pas explicitement queue_adapter contraire
  - **Notes** : Rails 8 défaut en test = `:test`. Si une ligne `config.active_job.queue_adapter = :inline` ou `:async` existe, la retirer. Sinon RAS.
  - **Test plan** : `bundle exec rails runner -e test "puts ActiveJob::Base.queue_adapter.class.name"` retourne `ActiveJob::QueueAdapters::TestAdapter`.

---

## 3. Retirer les `@skip "good_jobs absente"` devenus inutiles

- [x] **3.1 Mise à jour `spec/use_cases/scanner/claim_job_spec.rb`**
  - **Notes** : Le `@skip = "Table good_jobs absente — GoodJob install non joué"` peut être retiré ou réduit au seul cas `DB indisponible : ...`. La table existe désormais dans tous les envs où la DB est joignable.
  - **Test plan** : `bundle exec rspec spec/use_cases/scanner/claim_job_spec.rb` montre 6 examples PASSING (ex-pending).

- [x] **3.2 Mise à jour `spec/use_cases/scanner/fail_job_spec.rb`**
  - **Notes** : Le `skip "Table good_jobs absente"` dans `context "avec table good_jobs présente"` devient inutile.
  - **Test plan** : 1 example ex-pending passe.

- [x] **3.3 Mise à jour `spec/jobs/lease_release_job_spec.rb`**
  - **Notes** : Le `skip "Table good_jobs absente"` dans `context "avec table good_jobs présente"` devient inutile. 3 examples ex-pending.
  - **Test plan** : 3 examples passent.

- [x] **3.4 Mise à jour `spec/requests/mcp/scanner_tools_spec.rb`**
  - **Notes** : Les request specs qui dépendaient de good_jobs (ex : claim qui retourne effectivement un job) peuvent maintenant créer une row good_jobs en setup et valider l'invocation MCP claim avec succès (au lieu de juste tester le retour empty:true).
  - **Test plan** : ≥ 1 example supplémentaire qui valide le chemin complet claim → job retourné.

---

## 4. Documentation

- [x] **4.1 `docs/operating/deployment-docker-compose.md`**
  - **Notes** : Mentionner que `rails db:migrate` doit jouer la migration `good_jobs` au premier boot — c'était implicite avant. Avec la nouvelle migration, c'est tracé.
  - **Test plan** : `grep -i "good_jobs" docs/operating/deployment-docker-compose.md` ≥ 1 match.

---

## 5. Acceptance

- [x] **5.1 `bundle exec rspec` baisse le total `pending` d'au moins 10**
  - **Notes** : Avant le change : 597 examples, 0 failures, 10 pending. Après : ≥ 597 examples, 0 failures, ≤ 0 pending (les 10 pending good_jobs deviennent passing). Le total examples peut augmenter si §3.4 ajoute des tests.

- [x] **5.2 Run e2e local : `ScanJob.perform_later` ne lève plus**
  - **Notes** : `bundle exec rails runner "ScanJob.perform_later('scan_kind' => 'dns_records', 'target' => {'kind' => 'domain', 'value' => 'example.fr'}, 'idempotency_key' => 'manual-test-1', 'schema_version' => 1, 'requested_at' => Time.now.iso8601)"` retourne sans erreur ET insère une ligne dans `good_jobs`.

- [x] **5.3 Aucune régression Go**
  - **Notes** : `cd apps/scanner && go test ./...` reste vert (le change ne touche pas le code Go).

- [x] **5.4 Linters CI**
  - **Notes** : `bash scripts/check_spdx_headers.sh`, `check_doc_links.sh`, `check_no_billing.sh` restent verts.
