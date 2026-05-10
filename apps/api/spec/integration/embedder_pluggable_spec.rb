# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-embedder-pluggable/tasks.md §7.3 :
# "Cycle complet d'intégration : (a) boot avec local OK, (b) un fake
#  embedder qui lève UnavailableError → /agent/chat répond 503,
#  (c) après 5 échecs le circuit est :open, (d) doctor reporte le
#  circuit_state."
#
# §7.4 : provider local toujours zéro réseau.

RSpec.describe "Embedder pluggable e2e", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }

  before { Mcp::ToolRegistry.reset! }
  after  { Mcp::ToolRegistry.reset! ; Reconaut::Registry.reset! }

  describe "(a) boot avec provider=local" do
    it "Reconaut::Registry.default.embedder est Local par défaut" do
      Reconaut::Registry.reset!
      embedder = Reconaut::Registry.default.embedder
      expect(embedder).to be_a(Reconaut::Embedder::Local)
      expect(embedder.provider).to eq("local")
      expect(embedder.dim).to eq(384)
    end
  end

  describe "(b) /agent/chat répond 503 quand l'embedder externe est down" do
    it "503 + body embedding_provider_unavailable" do
      registry.scope_storage = storage
      registry.embedder = Class.new {
        def provider = "mistral"
        def dim = 384
      }.new

      retriever = Class.new {
        def call(_q) = raise Reconaut::Embedder::UnavailableError, "5xx"
      }.new

      Mcp::CoreTools.register_all!(
        retriever: retriever, scope_storage: storage,
        scan_enqueuer: registry.scan_enqueuer
      )

      post "/mcp/tools/agent_chat",
           params: { prompt: "x" }.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:service_unavailable)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:error]).to eq("embedding_provider_unavailable")
      expect(body[:provider]).to eq("mistral")
    end
  end

  describe "(c) après N échecs le circuit s'ouvre" do
    it "stats[:circuit_state] passe à :open" do
      inner = Class.new {
        def embed(texts:) = raise Reconaut::Embedder::UnavailableError, "down"
        def dim = 384
        def provider = "ollama"
      }.new

      r = Reconaut::Embedder::Resilient.new(inner,
        timeout_s: 0.5, breaker_failures: 3, breaker_window_s: 30, breaker_open_s: 60
      )
      3.times do
        expect { r.embed(texts: ["x"]) }.to raise_error(Reconaut::Embedder::UnavailableError)
      end
      expect(r.stats[:circuit_state]).to eq(:open)

      # Tout appel suivant lève CircuitOpenError sans toucher au backend.
      expect { r.embed(texts: ["x"]) }.to raise_error(Reconaut::Embedder::CircuitOpenError)
    end
  end

  describe "(d) doctor reporte le circuit_state" do
    it "imprime embedder_health avec circuit_state" do
      Reconaut::Registry.reset!
      report = Reconaut::Doctor.run(probes: {}, env: ENV)
      h = report.checks.find { |c| c.name == "embedder_health" }
      expect(h).not_to be_nil
      expect(h.details).to include(:circuit_state)
      expect(h.details[:provider]).to eq("local")
    end
  end

  describe "(§7.4) provider local : zéro réseau" do
    it "Net::HTTP.start n'est jamais invoqué" do
      Reconaut::Registry.reset!
      embedder = Reconaut::Embedder.build(env: { "RECONAUT_EMBEDDER_PROVIDER" => "local" })

      # Stub Net::HTTP.start → raise. Si Local touche au réseau, on saute.
      allow(Net::HTTP).to receive(:start).and_raise(StandardError, "réseau interdit")
      expect { embedder.embed(texts: ["banner"]) }.not_to raise_error
    end
  end
end
