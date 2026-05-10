# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-embedder-pluggable/specs/agent-interface/spec.md
#   -> Requirement: Embedder Resilience (mapping HTTP 503)

RSpec.describe "Mcp tools embedder 503 mapping", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }

  # Factory : retourne un retriever qui lève l'erreur passée pour
  # forcer la branche rescue du controller.
  def retriever_raising(error_class, message = "boom")
    Class.new {
      define_method(:initialize) { |e| @e = e }
      define_method(:call)       { |_q| raise @e.new(@m) }
      define_method(:_msg=)      { |m| @m = m }
    }.new(error_class).tap { |r| r.send(:_msg=, message) }
  end

  before do
    registry.scope_storage = storage
    Mcp::ToolRegistry.reset!
    # Embedder simulé : Ollama down (le provider remonté dans la 503).
    registry.embedder = Class.new {
      def provider = "ollama"
      def dim      = 384
    }.new
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  it "503 + body embedding_provider_unavailable quand le retriever lève UnavailableError" do
    Mcp::CoreTools.register_all!(
      retriever:     retriever_raising(Reconaut::Embedder::UnavailableError, "backend 502"),
      scope_storage: storage,
      scan_enqueuer: registry.scan_enqueuer
    )

    post "/mcp/tools/agent_chat",
         params:  { prompt: "modbus exposés en France" }.to_json,
         headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:service_unavailable) # 503
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:error]).to eq("embedding_provider_unavailable")
    expect(body[:provider]).to eq("ollama")
    expect(body[:reason]).to eq("backend-unavailable")
  end

  it "503 + reason=timeout sur Reconaut::Embedder::TimeoutError" do
    Mcp::CoreTools.register_all!(
      retriever:     retriever_raising(Reconaut::Embedder::TimeoutError, "after 2.5s"),
      scope_storage: storage,
      scan_enqueuer: registry.scan_enqueuer
    )

    post "/mcp/tools/agent_chat",
         params:  { prompt: "x" }.to_json,
         headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:service_unavailable)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:reason]).to eq("timeout")
  end

  it "503 + reason=circuit-open sur Reconaut::Embedder::CircuitOpenError" do
    Mcp::CoreTools.register_all!(
      retriever:     retriever_raising(Reconaut::Embedder::CircuitOpenError, "circuit"),
      scope_storage: storage,
      scan_enqueuer: registry.scan_enqueuer
    )

    post "/mcp/tools/agent_chat",
         params:  { prompt: "x" }.to_json,
         headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:service_unavailable)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:reason]).to eq("circuit-open")
  end

  it "audit log écrit même quand la requête se solde par 503" do
    Mcp::CoreTools.register_all!(
      retriever:     retriever_raising(Reconaut::Embedder::UnavailableError, "down"),
      scope_storage: storage,
      scan_enqueuer: registry.scan_enqueuer
    )

    post "/mcp/tools/agent_chat",
         params:  { prompt: "x" }.to_json,
         headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:service_unavailable)
    audit_entries = registry.audit_recorder.entries
    expect(audit_entries.size).to be >= 1
    expect(audit_entries.last[:template_id]).to eq("mcp:agent_chat")
  end
end
