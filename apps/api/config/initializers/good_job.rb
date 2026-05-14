# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only
#
# Configuration GoodJob 4.x : execution_mode + cron jobs.
#
# Source de vérité :
#   openspec/changes/add-good-job-cron-config/specs/platform/spec.md
#     -> Requirement: GoodJob cron schedule `lease_release` active
#
# Rappels architecturaux :
#   - Les jobs `scan:*` sont consommés par les workers Go (cf.
#     remote-scanner-agents) via le tool MCP `claim_scan_job`. GoodJob
#     côté Rails ne joue PAS ces jobs.
#   - Le seul rôle de GoodJob côté Rails en v1 est d'exécuter les cron
#     jobs internes — actuellement uniquement `LeaseReleaseJob` qui
#     re-queue les jobs scan dont le lease worker a expiré (>5 min).
#   - En `test`, le queue_adapter reste `:test` via
#     `config/environments/test.rb` — aucun worker GoodJob ne tourne,
#     aucun cron n'est déclenché.

# `:async` lance les workers GoodJob dans le process Puma (un thread
# dédié pour le polling cron). Suffisant pour `LeaseReleaseJob` qui est
# un UPDATE rapide plafonné à 1 invocation/minute. Pour un workload
# plus lourd, migrer vers `:external` (pod dédié `bundle exec good_job
# start`) sera un futur change.
Rails.application.config.good_job.execution_mode = :async unless Rails.env.test?

# Fréquence de poll : GoodJob vérifie toutes les 5 secondes s'il a
# un cron job à exécuter. Compromis entre fraîcheur (cron exécuté ≤ 5s
# après son tick théorique) et coût DB (poll = SELECT léger).
Rails.application.config.good_job.poll_interval = 5

# Pas d'archive des jobs finis. Les rows good_jobs sont supprimées
# après finished_at. Le journal d'audit (`agent_audit`) sert déjà à
# tracer les opérations métier (claim/submit/fail). Si un opérateur
# veut un historique : différé à `add-good-job-mission-control`.
Rails.application.config.good_job.preserve_job_records = false

# Cron jobs.
#   * lease_release : re-queue les jobs scan dont le lease worker a
#     expiré (performed_at < NOW() - 5 min et finished_at IS NULL).
#     Garantit le contrat at-least-once de remote-scanner-agents.
Rails.application.config.good_job.cron = {
  lease_release: {
    cron:        "* * * * *", # chaque minute
    class:       "LeaseReleaseJob",
    description: "Re-queue les jobs scan dont le lease worker a expiré (>5min) — remote-scanner-agents §1.6"
  }
}
