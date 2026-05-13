# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/mcp/core_tools"

# Cf. openspec/changes/add-worker-observability/specs/mcp-server/spec.md
#   -> Requirement: MCP Tool `list_workers`

RSpec.describe "MCP list_workers tool", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }

  let(:retriever) do
    Class.new {
      def call(_) = Agent::HybridRetriever::Response.new(
        rows: [], citations: [], warnings: [], retrieval_path: "graph", duration_ms: 1
      )
    }.new
  end

  before do
    Mcp::ToolRegistry.reset!
    registry.scope_storage = storage
    Mcp::CoreTools.register_all!(
      retriever:       retriever,
      scope_storage:   storage,
      scan_enqueuer:   registry.scan_enqueuer,
      heartbeat_store: registry.heartbeat_store
    )
    registry.heartbeat_store.clear!
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  it "POST /mcp/tools/list_workers retourne les workers actifs" do
    registry.heartbeat_store.record!(
      "schema_version" => 1,
      "worker_id"      => "w-fra1",
      "emitted_at"     => Time.now.utc.iso8601,
      "inflight_jobs"  => 0,
      "version"        => "0.0.0-test",
      "scan_kind"      => "dns_records"
    )

    post "/mcp/tools/list_workers",
      params: { recent_seconds: 60 }.to_json,
      headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body, symbolize_names: true)
    workers = body[:result][:workers]
    expect(workers.size).to eq(1)
    expect(workers.first[:worker_id]).to eq("w-fra1")
    expect(workers.first[:scan_kind]).to eq("dns_records")
    expect(workers.first[:version]).to eq("0.0.0-test")
  end

  it "retourne workers:[] quand aucun heartbeat" do
    post "/mcp/tools/list_workers",
      params: {}.to_json,
      headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:result][:workers]).to eq([])
  end

  it "list_workers est enregistré avec scope read:health" do
    tool = Mcp::ToolRegistry.fetch("list_workers")
    expect(tool.scopes).to include(:"read:health")
  end
end
