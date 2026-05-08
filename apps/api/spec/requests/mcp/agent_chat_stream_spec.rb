# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/mcp/core_tools"

# Spec de streaming SSE pour le tool MCP `agent_chat`.
# Cf. openspec/changes/mcp-as-primary-entrypoint/tasks.md §1.2 :
# "Test e2e : recevoir au moins 3 chunks ; assert que la concaténation
# des chunks égale la réponse complète et que chaque chunk porte ses
# citations."
RSpec.describe "MCP agent_chat streaming", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }

  let(:retriever_response) do
    Agent::HybridRetriever::Response.new(
      rows: [
        { "host_id" => "h1", "scanned_at" => "2026-05-01" },
        { "host_id" => "h2", "scanned_at" => "2026-05-02" },
        { "host_id" => "h3", "scanned_at" => "2026-05-03" }
      ],
      citations: [
        Agent::HybridRetriever::Citation.new(host_id: "h1", scanned_at: "2026-05-01", source: "graph"),
        Agent::HybridRetriever::Citation.new(host_id: "h2", scanned_at: "2026-05-02", source: "graph"),
        Agent::HybridRetriever::Citation.new(host_id: "h3", scanned_at: "2026-05-03", source: "vector")
      ],
      warnings: ["vector_unavailable"],
      retrieval_path: "hybrid",
      duration_ms: 55
    )
  end

  let(:retriever) do
    Class.new {
      def initialize(r) = (@r = r)
      def call(_) = @r
    }.new(retriever_response)
  end

  before do
    registry.scope_storage = storage
    Mcp::CoreTools.register_all!(
      retriever:     retriever,
      scope_storage: storage
    )
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  it "renvoie au moins 3 chunks tool_result quand Accept: text/event-stream" do
    post "/mcp/tools/agent_chat",
      params:  { prompt: "modbus en France" }.to_json,
      headers: {
        "Content-Type" => "application/json",
        "Accept"       => "text/event-stream",
        "X-Reconaut-Role" => "owner"
      }

    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to start_with("text/event-stream")

    events = parse_sse(response.body)
    # 1 start + 3 row + 1 done = 5
    expect(events.size).to be >= 3

    types = events.map { |e| e[:result][:type] }
    expect(types).to eq(%w[start row row row done])
  end

  it "concaténation des row chunks reconstitue la réponse complète" do
    post "/mcp/tools/agent_chat",
      params:  { prompt: "modbus en France" }.to_json,
      headers: {
        "Content-Type" => "application/json",
        "Accept"       => "text/event-stream",
        "X-Reconaut-Role" => "owner"
      }

    events = parse_sse(response.body)

    rows = events.select { |e| e[:result][:type] == "row" }.map { |e| e[:result][:row] }
    expect(rows.map { |r| r["host_id"] || r[:host_id] }).to eq(%w[h1 h2 h3])

    # chaque chunk row porte sa citation
    events.select { |e| e[:result][:type] == "row" }.each do |e|
      cit = e[:result][:citation]
      expect(cit[:host_id]).to be_a(String)
      expect(cit[:scanned_at]).to be_a(String)
    end
  end

  it "chaque chunk indique partial=true sauf le done final" do
    post "/mcp/tools/agent_chat",
      params:  { prompt: "x" }.to_json,
      headers: {
        "Content-Type" => "application/json",
        "Accept"       => "text/event-stream",
        "X-Reconaut-Role" => "owner"
      }

    events = parse_sse(response.body)
    expect(events[0..-2].all? { |e| e[:partial] == true }).to be true
    expect(events.last[:partial]).to be false
  end

  it "rétrocompatibilité : sans Accept SSE, la réponse reste JSON synchrone" do
    post "/mcp/tools/agent_chat",
      params:  { prompt: "modbus" }.to_json,
      headers: {
        "Content-Type"    => "application/json",
        "X-Reconaut-Role" => "owner"
      }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:tool]).to eq("agent_chat")
    expect(body[:result][:rows].size).to eq(3)
  end

  private

  # Parse minimal SSE : prend les blocs séparés par "\n\n", extrait le
  # champ `data:` de chaque bloc et le décode en JSON.
  def parse_sse(raw)
    raw.split("\n\n").reject(&:empty?).map do |block|
      data_line = block.lines.find { |l| l.start_with?("data:") }
      next unless data_line

      JSON.parse(data_line.sub(/^data:\s*/, ""), symbolize_names: true)
    end.compact
  end
end
