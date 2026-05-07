# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/agent/template_executor"
require_relative "../../../app/lib/graph_templates/core_set"

RSpec.describe Agent::TemplateExecutor do
  before { GraphTemplates::CoreSet.register_all! }

  # Fake metrics : memorise les increments / observations pour assertions.
  class CapturingMetrics
    attr_reader :counters, :histograms

    def initialize
      @counters   = []
      @histograms = []
    end

    def increment(name, **labels)
      @counters << [name, labels]
    end

    def observe(name, value, **labels)
      @histograms << [name, value, labels]
    end
  end

  describe "succes" do
    it "renvoie un Result :success et incremente retrieval_path graph" do
      metrics = CapturingMetrics.new
      runner  = ->(graph:, cypher:, params:) { [{ "host_id" => "h1" }] }
      exec = described_class.new(cypher_runner: runner, metrics: metrics)

      result = exec.call("cert_cluster", cert_sha256: "a" * 64)

      expect(result.ok?).to be true
      expect(result.rows).to eq([{ "host_id" => "h1" }])
      expect(result.nodes_touched).to eq(1)
      expect(metrics.counters).to include([:retrieval_path_total, { path: "graph" }])
      expect(metrics.histograms.first[0]).to eq(:retrieval_latency_seconds)
    end
  end

  describe "timeout" do
    it "retourne Result :timeout et incremente graph_template_timeout_total" do
      metrics = CapturingMetrics.new
      runner  = ->(graph:, cypher:, params:) { sleep 1; [] }
      exec = described_class.new(
        cypher_runner: runner,
        metrics: metrics,
        timeout_ms: 50
      )

      result = exec.call("cert_cluster", cert_sha256: "a" * 64)

      expect(result.status).to eq(:timeout)
      expect(result.fallback_required?).to be true
      expect(result.warning).to eq("graph_template_timeout")
      expect(metrics.counters).to include(
        [:graph_template_timeout_total, { template_id: "cert_cluster" }]
      )
    end
  end

  describe "indisponibilite (extension manquante)" do
    it "retourne Result :unavailable et incremente graph_unavailable_total" do
      metrics = CapturingMetrics.new
      runner = ->(*) { raise Agent::TemplateExecutor::GraphUnavailableError, "extension not loaded" }
      exec = described_class.new(cypher_runner: runner, metrics: metrics)

      result = exec.call("cert_cluster", cert_sha256: "a" * 64)

      expect(result.status).to eq(:unavailable)
      expect(result.fallback_required?).to be true
      expect(result.warning).to eq("graph_unavailable")
      expect(metrics.counters).to include(
        [:graph_unavailable_total, { reason: "extension_missing" }]
      )
    end

    it "categorise permission denied" do
      metrics = CapturingMetrics.new
      runner = ->(*) { raise Agent::TemplateExecutor::GraphUnavailableError, "permission denied for relation" }
      exec = described_class.new(cypher_runner: runner, metrics: metrics)

      exec.call("cert_cluster", cert_sha256: "a" * 64)

      expect(metrics.counters).to include(
        [:graph_unavailable_total, { reason: "permission_denied" }]
      )
    end
  end

  describe "validation des parametres avant execution" do
    it "leve ParamOutOfRangeError sans appeler le runner" do
      runner = ->(*) { raise "should not be called" }
      exec = described_class.new(cypher_runner: runner)

      expect {
        exec.call("host_neighborhood", host_id: "h1", depth: 10)
      }.to raise_error(GraphTemplates::ParamOutOfRangeError)
    end

    it "leve UnknownTemplateError pour un id inconnu" do
      runner = ->(*) { raise "should not be called" }
      exec = described_class.new(cypher_runner: runner)

      expect { exec.call("evil", {}) }
        .to raise_error(GraphTemplates::UnknownTemplateError)
    end
  end
end
