# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../../../app/lib/agent/hybrid_retriever"
require_relative "../../../app/lib/graph_templates/core_set"

RSpec.describe Agent::HybridRetriever do
  before { GraphTemplates::CoreSet.register_all! }

  # Petits doublures controlees.
  class StubLLM
    def initialize(payload)
      @payload = payload
    end

    def complete(prompt:)
      @payload
    end
  end

  class CapturingMetrics
    attr_reader :counters, :histograms

    def initialize
      @counters   = []
      @histograms = []
    end

    def increment(name, **labels) = @counters << [name, labels]
    def observe(name, value, **labels) = @histograms << [name, value, labels]
  end

  def build_pipeline(llm_response:, runner: nil, vector: ->(_) { [] }, metrics: CapturingMetrics.new)
    router = Agent::QueryRouter.new(llm_client: StubLLM.new(llm_response))
    runner ||= ->(graph:, cypher:, params:) { [] }
    executor = Agent::TemplateExecutor.new(cypher_runner: runner, metrics: metrics)
    [
      described_class.new(
        router: router,
        template_executor: executor,
        vector_retriever: vector,
        metrics: metrics
      ),
      metrics
    ]
  end

  describe "chemin hybride" do
    it "compose vector + graphe et marque retrieval_path=hybrid" do
      llm = JSON.generate(
        templates: [
          { template_id: "cert_cluster", params: { cert_sha256: "a" * 64 } }
        ],
        semantic_query: "nginx"
      )
      runner = ->(graph:, cypher:, params:) {
        [{ "host_id" => "h1", "scanned_at" => "2026-05-01T00:00:00Z" }]
      }
      vector = ->(q) {
        [{ "host_id" => "h2", "scanned_at" => "2026-05-02T00:00:00Z" }]
      }
      retriever, metrics = build_pipeline(llm_response: llm, runner: runner, vector: vector)

      response = retriever.call("hotes nginx partageant un cert")

      expect(response.retrieval_path).to eq("hybrid")
      expect(response.rows.length).to eq(2)
      expect(response.citations.map(&:host_id)).to contain_exactly("h1", "h2")
      expect(response.warnings).to be_empty
      expect(metrics.counters).to include([:retrieval_path_total, { path: "hybrid" }])
    end
  end

  describe "chemin graphe pur (rappel vectoriel vide)" do
    it "marque retrieval_path=graph" do
      llm = JSON.generate(
        templates: [{ template_id: "cert_cluster", params: { cert_sha256: "a" * 64 } }],
        semantic_query: ""
      )
      runner = ->(*) { [{ "host_id" => "h1" }] }
      vector = ->(_) { [] }
      retriever, metrics = build_pipeline(llm_response: llm, runner: runner, vector: vector)

      response = retriever.call("partage cert")
      expect(response.retrieval_path).to eq("graph")
      expect(metrics.counters).to include([:retrieval_path_total, { path: "graph" }])
    end
  end

  describe "chemin vectoriel pur" do
    it "marque retrieval_path=vector quand le LLM ne propose aucun template" do
      llm = JSON.generate(templates: [], semantic_query: "nginx 1.18")
      vector = ->(_q) { [{ "host_id" => "v1" }] }
      retriever, metrics = build_pipeline(llm_response: llm, vector: vector)

      response = retriever.call("nginx vulnerables")
      expect(response.retrieval_path).to eq("vector")
      expect(metrics.counters).to include([:retrieval_path_total, { path: "vector" }])
    end
  end

  describe "ensemble vide" do
    it "renvoie retrieval_path=none et 0 row sans fabriquer de resultat" do
      llm = JSON.generate(templates: [], semantic_query: "")
      retriever, _metrics = build_pipeline(llm_response: llm, vector: ->(_) { [] })

      response = retriever.call("requete vague")
      expect(response.rows).to be_empty
      expect(response.retrieval_path).to eq("none")
    end
  end

  describe "deduplication par host_id" do
    it "ne renvoie qu'une ligne quand les deux chemins citent le meme hote" do
      llm = JSON.generate(
        templates: [{ template_id: "cert_cluster", params: { cert_sha256: "a" * 64 } }],
        semantic_query: "nginx"
      )
      runner = ->(*) { [{ "host_id" => "h1", "scanned_at" => "t1" }] }
      vector = ->(_) { [{ "host_id" => "h1", "scanned_at" => "t1-bis" }] }
      retriever, _ = build_pipeline(llm_response: llm, runner: runner, vector: vector)

      response = retriever.call("hotes nginx avec cert")
      expect(response.rows.length).to eq(1)
    end
  end

  describe "degradation gracieuse quand le graphe est down" do
    it "tombe en vector + warning graph_unavailable" do
      llm = JSON.generate(
        templates: [{ template_id: "cert_cluster", params: { cert_sha256: "a" * 64 } }],
        semantic_query: "nginx"
      )
      runner = ->(*) { raise Agent::TemplateExecutor::GraphUnavailableError, "extension not loaded" }
      vector = ->(_) { [{ "host_id" => "h1" }] }
      retriever, _ = build_pipeline(llm_response: llm, runner: runner, vector: vector)

      response = retriever.call("partage cert")
      expect(response.warnings).to include("graph_unavailable")
      expect(response.rows).not_to be_empty
      expect(response.retrieval_path).to eq("vector")
    end
  end

  describe "router casse" do
    it "tombe en vector + warning router_invalid_response sur JSON malforme" do
      vector = ->(_) { [{ "host_id" => "h1" }] }
      retriever, _ = build_pipeline(
        llm_response: "not json",
        vector: vector
      )

      response = retriever.call("hotes")
      expect(response.warnings).to include("router_invalid_response")
      expect(response.retrieval_path).to eq("vector")
    end

    it "tombe en vector quand le LLM choisit un template inconnu" do
      llm = JSON.generate(
        templates: [{ template_id: "evil", params: {} }],
        semantic_query: "fallback"
      )
      vector = ->(_) { [{ "host_id" => "h1" }] }
      retriever, _ = build_pipeline(llm_response: llm, vector: vector)

      response = retriever.call("hotes")
      expect(response.warnings).to include("router_rejected_plan")
      expect(response.retrieval_path).to eq("vector")
    end
  end

  describe "rappel vectoriel down" do
    it "garde le chemin graphe et ajoute warning vector_unavailable" do
      llm = JSON.generate(
        templates: [{ template_id: "cert_cluster", params: { cert_sha256: "a" * 64 } }],
        semantic_query: "nginx"
      )
      runner = ->(*) { [{ "host_id" => "h1" }] }
      vector = ->(_) { raise "embedder down" }
      retriever, _ = build_pipeline(llm_response: llm, runner: runner, vector: vector)

      response = retriever.call("hotes")
      expect(response.warnings).to include("vector_unavailable")
      expect(response.retrieval_path).to eq("graph")
      expect(response.rows.length).to eq(1)
    end
  end
end
