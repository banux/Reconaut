# Spec delta : platform

## ADDED Requirements

### Requirement: GoodJob cron schedule `lease_release` active
Le fichier `config/initializers/good_job.rb` DOIT configurer `Rails.application.config.good_job.cron` avec au minimum une entrée `lease_release` qui :

- exécute la classe `LeaseReleaseJob`,
- est schédulée toutes les minutes (cron expression `* * * * *`),
- porte une description claire (par ex. "Re-queue les jobs scan dont le lease worker a expiré (>5min)").

En `production` et `development`, `config.good_job.execution_mode` DOIT être `:async` — GoodJob lance ses workers dans le process Puma, suffisant pour exécuter le cron léger `LeaseReleaseJob`. En `test`, le queue_adapter reste `:test` (override existant dans `config/environments/test.rb`), donc aucun worker GoodJob ne tourne.

#### Scenario: Boot Rails → execution_mode=:async en dev/prod
- **GIVEN** `RAILS_ENV=development` ou `production`
- **WHEN** Rails démarre
- **THEN** `Rails.application.config.good_job.execution_mode` retourne `:async`
- **AND** un nouveau thread GoodJob tourne en arrière-plan dans le process.

#### Scenario: Boot Rails → cron contient lease_release
- **GIVEN** Rails booté en `development`
- **WHEN** un spec lit `Rails.application.config.good_job.cron`
- **THEN** la map contient une clé `:lease_release` (ou `"lease_release"`)
- **AND** la valeur a `class: "LeaseReleaseJob"` et `cron: "* * * * *"`
- **AND** la valeur a une `description` non vide.

#### Scenario: LeaseReleaseJob tourne effectivement chaque minute en dev
- **GIVEN** Rails développement avec GoodJob `:async`
- **WHEN** on attend 70 secondes
- **THEN** `LeaseReleaseJob.perform_later` a été appelé au moins une fois (vérifiable via un compteur instrumenté ou via inspection des logs `good_job` dans un test e2e — pour rspec, on se contente de vérifier la configuration ; la validation runtime se fait via un test manuel documenté).

#### Scenario: Pas de cron en test
- **GIVEN** `RAILS_ENV=test`
- **WHEN** une spec lit `ActiveJob::Base.queue_adapter`
- **THEN** c'est `ActiveJob::QueueAdapters::TestAdapter` (override de `config/environments/test.rb`)
- **AND** aucun thread GoodJob ne tourne (pas de polling DB).
