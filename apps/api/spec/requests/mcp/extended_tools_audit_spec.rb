# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/mcp/core_tools"

# Cf. openspec/changes/mcp-as-primary-entrypoint/tasks.md §5.1 :
# "Chaque outil ajouté en §1 a au moins (a) un spec happy path,
#  (b) un spec d'autorisation (rôle insuffisant → unauthorized),
#  (c) un spec d'audit (ligne écrite avec tool_name)."
#
# Les specs (a) et (b) sont dans spec/lib/mcp/{scan_query_tools,
# agent_chat_tool}_spec.rb. Ce fichier complète avec (c) — chaque
# nouvel outil produit une ligne d'audit avec template_id mcp:<name>.
RSpec.describe "MCP extended tools audit log", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }
  let(:audit)    { Agent::AuditRecorder::InMemoryRecorder.new }

  let(:retriever_response) do
    Agent::HybridRetriever::Response.new(
      rows: [{ "host_id" => "h1", "scanned_at" => "2026-05-01" }],
      citations: [Agent::HybridRetriever::Citation.new(host_id: "h1", scanned_at: "2026-05-01")],
      warnings: [], retrieval_path: "graph", duration_ms: 10
    )
  end

  let(:retriever) do
    Class.new {
      def initialize(r) = (@r = r)
      def call(_) = @r
    }.new(retriever_response)
  end

  before do
    registry.scope_storage  = storage
    registry.audit_recorder = audit
    Mcp::CoreTools.register_all!(
      retriever:     retriever,
      scope_storage: storage,
      scan_enqueuer: registry.scan_enqueuer,
      scan_store:    registry.scan_store
    )
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  it "list_scans écrit une ligne d'audit avec template_id mcp:list_scans" do
    post "/mcp/tools/list_scans",
      params: {}.to_json,
      headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "owner" }

    expect(response).to have_http_status(:ok)
    entry = audit.entries.last
    expect(entry[:status]).to eq(:success)
    expect(entry[:template_id]).to eq("mcp:list_scans")
  end

  it "get_scan_status écrit une ligne d'audit" do
    post "/mcp/tools/get_scan_status",
      params: { scan_id: "missing" }.to_json,
      headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "owner" }

    expect(response).to have_http_status(:ok)
    expect(audit.entries.last[:template_id]).to eq("mcp:get_scan_status")
  end

  it "agent_chat écrit une ligne d'audit avec template_id mcp:agent_chat" do
    post "/mcp/tools/agent_chat",
      params: { prompt: "modbus" }.to_json,
      headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "owner" }

    expect(response).to have_http_status(:ok)
    expect(audit.entries.last[:template_id]).to eq("mcp:agent_chat")
  end
end
