# frozen_string_literal: true

# ScanJob : ActiveJob qui transporte un payload `ScanJobV1` validé jusqu'à
# la table `good_jobs`. Le worker Go consomme ensuite directement la table.
#
# Source de vérité :
#   openspec/changes/add-tech-stack/specs/architecture/spec.md
#     -> Requirement: Rails ↔ Go Communication via GoodJob
#   openspec/changes/add-tech-stack/tasks.md section 3.2
#
# Le job ne fait AUCUNE logique de scan côté Rails (cf. Requirement: Scan
# Workers Runtime — aucun ouverture de socket vers une cible). `perform`
# ne tourne que si pour une raison opérationnelle GoodJob essayait
# d'exécuter le job côté Rails (par ex. queue_adapter `:test` ou bug de
# config) ; dans ce cas on lève pour ne pas masquer l'erreur.
class ScanJob < ApplicationJob
  queue_as :scan

  # Le payload est un Hash conforme au schéma `ScanJobV1` (cf.
  # `packages/job-schema/scan_job_v1.json`). On le sérialise tel quel ;
  # GoodJob le persiste dans `good_jobs.serialized_params` au format JSON
  # standard ActiveJob.
  def perform(payload)
    raise NotImplementedError, <<~MSG
      ScanJob#perform must NOT run inside the Rails process — scan logic
      lives in the Go worker (cf. spec architecture: Scan Workers Runtime).
      Si vous voyez cette exception, l'adapter ActiveJob est probablement
      configuré sur `:inline` ou `:async`. En production, l'adapter doit
      être `:good_job` et seul le worker Go consomme la queue `scan`.
      Reçu : #{payload.inspect}
    MSG
  end
end
