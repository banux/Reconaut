# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-embedding-pipeline/specs/agent-interface/spec.md
#   -> Requirement: Host Indexing Pipeline

RSpec.describe IndexHostJob, type: :job do
  before do
    ActiveJob::Base.queue_adapter = :test
  end

  describe "#perform" do
    it "invoque EmbeddingIndexer.index! avec le host trouvé" do
      host = Host.create!(ip: "192.0.2.42")
      expect(Reconaut::EmbeddingIndexer).to receive(:index!).with(host)
      described_class.new.perform(host.id)
    end

    it "no-op gracieux si host_id inconnu (host supprimé entre enqueue et exécution)" do
      expect(Reconaut::EmbeddingIndexer).not_to receive(:index!)
      expect {
        described_class.new.perform("00000000-0000-0000-0000-000000000000")
      }.not_to raise_error
    end
  end

  describe "retry policy" do
    it "retry sur UnavailableError (5 tentatives)" do
      expect(described_class.retry_on_classes).to include(Reconaut::Embedder::UnavailableError)
    end

    it "retry sur TimeoutError (3 tentatives)" do
      expect(described_class.retry_on_classes).to include(Reconaut::Embedder::TimeoutError)
    end

    it "retry sur CircuitOpenError (5 tentatives)" do
      expect(described_class.retry_on_classes).to include(Reconaut::Embedder::CircuitOpenError)
    end
  end

  # Helper pour exposer la liste des classes retry-able déclarées par
  # `retry_on` (pas exposé en public par ActiveJob, on lit
  # rescue_handlers).
  def described_class.retry_on_classes
    rescue_handlers.map { |h| h.first.is_a?(Class) ? h.first : Object.const_get(h.first.to_s) rescue nil }.compact
  end
end
