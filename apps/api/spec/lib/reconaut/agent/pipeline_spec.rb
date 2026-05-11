# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-embedding-pipeline/specs/agent-interface/spec.md
#   -> Requirement: Pipeline Wired into Registry at Boot

RSpec.describe Reconaut::Agent::Pipeline do
  let(:embedder) do
    Class.new {
      def embed(texts:) = texts.map { |_| Array.new(384, 0.5) }
      def dim     = 384
      def provider = "local"
    }.new
  end

  let(:registry) do
    reg = Reconaut::Registry.new
    reg.embedder = embedder
    reg
  end

  describe ".build" do
    it "retourne un Agent::HybridRetriever câblé" do
      retriever = described_class.build(registry: registry)
      expect(retriever).to be_a(Agent::HybridRetriever)
    end

    it "le retriever construit utilise VectorOnlyRouter (force vector-only)" do
      retriever = described_class.build(registry: registry)
      response = retriever.call("modbus")

      # En vector-only avec table embeddings vide, on attend
      # retrieval_path=none (aucun row) sans crash.
      expect(response).to be_a(Agent::HybridRetriever::Response)
      expect(response.rows).to eq([])
    end

    it "le router VectorOnly preserve la query brute en semantic_query" do
      decision = described_class::VectorOnlyRouter.new.route("liste les dns esiea")
      expect(decision.semantic_query).to eq("liste les dns esiea")
      expect(decision.graph_path?).to be false
      expect(decision.templates).to eq([])
    end

    it "le NullTemplateExecutor retourne toujours rows=[] ok?=true" do
      r = described_class::NullTemplateExecutor.new.call("any", {})
      expect(r.rows).to eq([])
      expect(r.ok?).to be true
      expect(r.warning).to be_nil
    end
  end
end
