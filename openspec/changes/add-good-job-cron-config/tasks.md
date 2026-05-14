# Tâches : add-good-job-cron-config

Checklist : activer le cron `LeaseReleaseJob` via `config.good_job.cron` en mode `:async`. Chaque tâche inclut notes + test plan.

---

## 1. Configuration

- [ ] **1.1 `config/initializers/good_job.rb`**
  - **Notes** : Nouveau fichier qui :
    1. Set `Rails.application.config.good_job.execution_mode = :async` (uniquement si pas en test — `unless Rails.env.test?`). Le test env utilise `:test` adapter via `config/environments/test.rb`.
    2. Set `Rails.application.config.good_job.poll_interval = 5` (secondes).
    3. Set `Rails.application.config.good_job.preserve_job_records = false`.
    4. Set `Rails.application.config.good_job.cron = { lease_release: { cron: "* * * * *", class: "LeaseReleaseJob", description: "Re-queue les jobs scan dont le lease worker a expiré (>5min) — remote-scanner-agents §1.6" } }`.
  - SPDX header au début du fichier.
  - **Test plan** : (a) `bundle exec rails runner -e development "puts Rails.application.config.good_job.cron.inspect"` retourne la map avec `lease_release`. (b) `bundle exec rails runner -e development "puts Rails.application.config.good_job.execution_mode.inspect"` retourne `:async`. (c) En `test`, le adapter reste `:test`.

- [ ] **1.2 Spec `spec/config/good_job_config_spec.rb`**
  - **Notes** : Spec léger qui charge la config et vérifie :
    - `Rails.application.config.good_job.cron` contient `lease_release` avec `class: "LeaseReleaseJob"`, `cron: "* * * * *"`, `description` non vide.
    - `Rails.application.config.good_job.poll_interval == 5`.
    - `Rails.application.config.good_job.preserve_job_records == false`.
    - En env `test`, le queue_adapter reste `:test` (ActiveJob::Base.queue_adapter.class.name).
  - **Test plan** : `bundle exec rspec spec/config/good_job_config_spec.rb` vert.

---

## 2. Documentation

- [ ] **2.1 `docs/operating/deployment-docker-compose.md`**
  - **Notes** : Ajouter une section "Cron & maintenance" qui explique que GoodJob tourne en `:async` dans le service `api`. Le LeaseReleaseJob s'exécute chaque minute pour assurer le contrat at-least-once des workers. Pas de service `goodjob` séparé en v1.
  - **Test plan** : `grep -i "cron\|LeaseRelease" docs/operating/deployment-docker-compose.md` ≥ 1 match.

- [ ] **2.2 `docs/operating/deployment-helm.md`**
  - **Notes** : Mention équivalente. Pas de pod séparé en v1 ; le LeaseRelease tourne dans le pod `api`. Si l'opérateur veut scaler horizontalement la file (multi-replica api), considérer passer à `:external` mode (différé).
  - **Test plan** : `grep -i "LeaseRelease\|cron" docs/operating/deployment-helm.md` ≥ 1 match.

- [ ] **2.3 `docs/architecture/remote-scanners.md`**
  - **Notes** : Dans la section "Quand un worker crashe", remplacer "le job `LeaseReleaseJob` (recurring, toutes les 60 s)" par un lien vers ce change et préciser que le scheduling est désormais actif (config.good_job.cron).
  - **Test plan** : `grep -i "add-good-job-cron-config" docs/architecture/remote-scanners.md` ≥ 1 match.

---

## 3. Acceptance

- [ ] **3.1 Suite Ruby reste verte**
  - `bundle exec rspec` — 612 examples ou plus, 0 failures (le nouveau spec ajoute 4 examples ; total attendu ≥ 616).

- [ ] **3.2 Tests Go inchangés**
  - `cd apps/scanner && go test ./...` reste vert (ce change ne touche pas le Go).

- [ ] **3.3 Linters CI**
  - `bash scripts/check_spdx_headers.sh` (le nouveau fichier porte SPDX), `check_doc_links.sh`, `check_no_billing.sh` restent verts.

- [ ] **3.4 E2E manuel documenté**
  - Procédure dans `docs/operating/deployment-docker-compose.md` :
    1. `docker compose up postgres api` (sans scanners pour simplifier)
    2. Insérer manuellement une row good_jobs avec `performed_at = NOW() - INTERVAL '10 minutes'` et `finished_at IS NULL`
    3. Attendre ~70 secondes
    4. Vérifier que `performed_at` est devenu `NULL` côté DB (LeaseReleaseJob a tourné).
