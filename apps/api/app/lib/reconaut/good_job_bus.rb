# frozen_string_literal: true

require_relative "../job_schema/registry"

module Reconaut
  # GoodJobBus : implémentation production du `job_bus` consommé par
  # `Reconaut::ScanEnqueuer`. Conforme au contrat
  # `enqueue(payload:) -> { scan_id: <string> }`.
  #
  # Source de vérité :
  #   openspec/changes/add-tech-stack/specs/architecture/spec.md
  #     -> Requirement: Rails ↔ Go Communication via GoodJob
  #     -> Scenario: Demande de scan se matérialise comme un job GoodJob
  #   openspec/changes/add-tech-stack/tasks.md section 3.2
  #
  # Le bus appelle `ScanJob.perform_later(payload)`. ActiveJob renvoie un
  # `ActiveJob::ConfiguredJob`/`ActiveJob::Base` instance qui expose
  # `provider_job_id` (la PK de la ligne `good_jobs` lorsqu'on tourne avec
  # l'adapter `:good_job`) et `job_id` (UUID ActiveJob, présent quel que
  # soit l'adapter). On utilise `provider_job_id` quand il est dispo et on
  # retombe sur `job_id` sinon (utile en mode `:test` / `:inline`).
  class GoodJobBus
    JobNotEnqueuedError = Class.new(StandardError)

    def enqueue(payload:)
      job = ScanJob.perform_later(payload)
      raise JobNotEnqueuedError, "perform_later returned nil" unless job

      scan_id = job.provider_job_id || job.job_id
      raise JobNotEnqueuedError, "no scan_id available" unless scan_id

      { scan_id: scan_id.to_s }
    end
  end
end
