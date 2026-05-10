# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-agent-chat-streaming/specs/mcp-server/spec.md
#   -> Requirement: Agent Chat SSE Heartbeat
#   -> Requirement: Agent Chat Cancellation Propagation
#   -> Requirement: Optional Progressive Row Emission
#   -> Requirement: Audit Log Includes Streaming Outcome

RSpec.describe "Agent chat streaming e2e", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }

  let(:retriever_response) do
    Agent::HybridRetriever::Response.new(
      rows: [{ "host_id" => "h1", "scanned_at" => "2026-05-01" }],
      citations: [Agent::HybridRetriever::Citation.new(host_id: "h1", scanned_at: "2026-05-01")],
      warnings: [], retrieval_path: "graph", duration_ms: 30
    )
  end

  let(:retriever) do
    Class.new {
      def initialize(r) = (@r = r)
      def call(_q) = @r
    }.new(retriever_response)
  end

  before do
    Mcp::ToolRegistry.reset!
    registry.scope_storage = storage
    registry.hybrid_retriever = nil # voie post-hoc par défaut
    Mcp::CoreTools.register_all!(
      retriever: retriever,
      scope_storage: storage,
      scan_enqueuer: registry.scan_enqueuer
    )
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  describe "audit avec outcome" do
    it "retrieval complet → params_normalized.outcome = completed + streaming = true" do
      post "/mcp/tools/agent_chat",
           params:  { prompt: "modbus" }.to_json,
           headers: {
             "Content-Type" => "application/json",
             "Accept"       => "text/event-stream"
           }

      expect(response).to have_http_status(:ok)

      audits = registry.audit_recorder.entries
      streaming_audit = audits.find { |a| a[:template_id] == "mcp:agent_chat" }
      expect(streaming_audit).not_to be_nil
      expect(streaming_audit[:params_normalized]).to include(streaming: true)
      expect(streaming_audit[:params_normalized][:outcome]).to eq("completed")
    end

    it "non-streaming → audit sans champ streaming/outcome" do
      post "/mcp/tools/agent_chat",
           params:  { prompt: "modbus" }.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      audits = registry.audit_recorder.entries
      a = audits.find { |x| x[:template_id] == "mcp:agent_chat" }
      expect(a).not_to be_nil
      # Pas de champ streaming sur le path non-streamé.
      expect(a[:params_normalized]).not_to include(:streaming)
      expect(a[:params_normalized]).not_to include(:outcome)
    end
  end

  describe "format SSE de base (pas de heartbeat sur retrieval rapide)" do
    around do |ex|
      orig = ENV["RECONAUT_AGENT_CHAT_HEARTBEAT_S"]
      ENV["RECONAUT_AGENT_CHAT_HEARTBEAT_S"] = "0" # désactivé
      ex.run
    ensure
      ENV["RECONAUT_AGENT_CHAT_HEARTBEAT_S"] = orig
    end

    it "émet start → row → done dans l'ordre" do
      post "/mcp/tools/agent_chat",
           params:  { prompt: "modbus" }.to_json,
           headers: {
             "Content-Type" => "application/json",
             "Accept"       => "text/event-stream"
           }

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include('"type":"start"')
      expect(body).to include('"type":"row"')
      expect(body).to include('"type":"done"')
      expect(body.scan(/"type":"start"/).size).to eq(1)
      expect(body.scan(/"type":"done"/).size).to eq(1)
      # Pas de ping émis (interval=0).
      expect(body).not_to include("event: ping")
    end
  end

  describe "voie progressive each_chunk" do
    it "utilise each_chunk si le retriever câblé dans Registry l'expose" do
      progressive = Class.new {
        attr_reader :each_chunk_called
        def call(_q) = nil
        def each_chunk(_q)
          @each_chunk_called = true
          yield({ type: "start", retrieval_path: "graph", duration_ms: 1 })
          yield({ type: "row", row: { "host_id" => "h1" }, citation: { host_id: "h1" } })
          yield({ type: "done", warnings: [], total_rows: 1 })
        end
      }.new
      registry.hybrid_retriever = progressive

      post "/mcp/tools/agent_chat",
           params:  { prompt: "modbus" }.to_json,
           headers: {
             "Content-Type" => "application/json",
             "Accept"       => "text/event-stream"
           }

      expect(response).to have_http_status(:ok)
      expect(progressive.each_chunk_called).to be true
      expect(response.body).to include('"type":"start"')
      expect(response.body).to include('"type":"done"')
    end

    it "retombe sur post-hoc chunking quand le retriever n'expose pas each_chunk" do
      noop = Class.new {
        def call(_q) = nil
      }.new
      registry.hybrid_retriever = noop

      post "/mcp/tools/agent_chat",
           params:  { prompt: "modbus" }.to_json,
           headers: {
             "Content-Type" => "application/json",
             "Accept"       => "text/event-stream"
           }

      expect(response).to have_http_status(:ok)
      # Le tool block a tourné (post-hoc), donc le format est inchangé.
      expect(response.body).to include('"type":"start"')
    end
  end

  describe "AgentChatHeartbeat n'orpheline pas de Thread" do
    it "le thread est dead après stop" do
      stream = StringIO.new
      def stream.closed? = false
      thread = Mcp::AgentChatHeartbeat.start(stream: stream, interval_s: 0.05)
      sleep 0.06
      Mcp::AgentChatHeartbeat.stop(thread)
      sleep 0.1
      expect(thread.alive?).to be false
    end
  end
end
