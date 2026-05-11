# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# IndexHostJob : vectorise un Host en arrière-plan via GoodJob. Hooked
# par `Host.after_create_commit` et `Host.after_update_commit` (sur les
# champs embedding-pertinents).
#
# Cf. openspec/changes/add-embedding-pipeline/specs/agent-interface/spec.md
#   -> Requirement: Host Indexing Pipeline
#
# Idempotent : `Reconaut::EmbeddingIndexer.index!` upsert sur `host_id`.
# Le retry GoodJob est sûr.
class IndexHostJob < ApplicationJob
  queue_as :default

  retry_on ::Reconaut::Embedder::UnavailableError,  wait: 30.seconds, attempts: 5
  retry_on ::Reconaut::Embedder::TimeoutError,      wait: 30.seconds, attempts: 3
  retry_on ::Reconaut::Embedder::CircuitOpenError,  wait: 60.seconds, attempts: 5

  discard_on ActiveJob::DeserializationError

  def perform(host_id)
    host = Host.find_by(id: host_id)
    return if host.nil? # host supprimé entre enqueue et exécution

    Reconaut::EmbeddingIndexer.index!(host)
  end
end
