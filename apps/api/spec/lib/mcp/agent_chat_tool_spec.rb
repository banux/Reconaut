# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/mcp/core_tools"
require_relative "../../../app/use_cases/scopes/storage"

# Specs du tool MCP `agent_chat`.
# Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
# (Requirement: MCP Tool Surface, scope agent:chat).
RSpec.describe "Mcp::CoreTools agent_chat tool" do
  let(:scope_storage) { Scopes::Storage::InMemory.new }

  let(:retriever_response) do
    Agent::HybridRetriever::Response.new(
      rows: [
        { "host_id" => "h1", "scanned_at" => "2026-05-01" },
        { "host_id" => "h2", "scanned_at" => "2026-05-02" }
      ],
      citations: [
        Agent::HybridRetriever::Citation.new(host_id: "h1", scanned_at: "2026-05-01"),
        Agent::HybridRetriever::Citation.new(host_id: "h2", scanned_at: "2026-05-02")
      ],
      warnings: [],
      retrieval_path: "graph",
      duration_ms: 42
    )
  end

  let(:retriever) do
    Class.new {
      def initialize(r) = (@r = r)
      def call(_) = @r
    }.new(retriever_response)
  end

  before do
    Mcp::ToolRegistry.reset!
    Mcp::CoreTools.register_all!(
      retriever:     retriever,
      scope_storage: scope_storage
    )
  end

  let(:tool) { Mcp::ToolRegistry.fetch("agent_chat") }

  it "expose le scope agent:chat et un schema prompt+context" do
    expect(tool.scopes).to eq([:"agent:chat"])
    expect(tool.params_schema.keys).to contain_exactly(:prompt, :context)
  end

  it "happy path : delegue au retriever et renvoie rows + citations" do
    result = tool.call(
      params:        { prompt: "modbus en France" },
      caller_id:     "operator",
      caller_scopes: [:"agent:chat"]
    )
    expect(result[:rows].size).to eq(2)
    expect(result[:citations].first[:host_id]).to eq("h1")
    expect(result[:retrieval_path]).to eq("graph")
    expect(result[:duration_ms]).to eq(42)
  end

  it "context optionnel : pas requis" do
    result = tool.call(
      params:        { prompt: "ping" },
      caller_id:     "operator",
      caller_scopes: [:"agent:chat"]
    )
    expect(result[:rows]).not_to be_empty
  end

  it "rejette sans le scope agent:chat" do
    expect {
      tool.call(
        params:        { prompt: "x" },
        caller_id:     "operator",
        caller_scopes: [:"read:hosts"]
      )
    }.to raise_error(Mcp::ScopeError, /agent:chat/)
  end

  it "rejette un prompt vide" do
    expect {
      tool.call(
        params:        { prompt: "" },
        caller_id:     "operator",
        caller_scopes: [:"agent:chat"]
      )
    }.to raise_error(Mcp::ParamOutOfRangeError, /prompt/)
  end
end
