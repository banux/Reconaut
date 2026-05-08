# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/mcp/core_tools"
require_relative "../../../app/use_cases/scopes/storage"

# Cf. openspec/changes/reposition-as-agent-knowledge-base/specs/integrations/spec.md
# (Requirement: Source Tagging on Ingested Data) et tasks.md §2.3 / §4.2.
#
# Les outils MCP de lecture (`search_hosts`, `get_host`) DOIVENT
# propager le champ `source` (ou `sources` si plusieurs origines) tel
# qu'il a été matérialisé dans le graphe par le ScanResultIngestor.
RSpec.describe "Source tagging via outils de lecture MCP" do
  let(:scope_storage) { Scopes::Storage::InMemory.new }

  def retriever_with(rows)
    response = Agent::HybridRetriever::Response.new(
      rows: rows,
      citations: rows.map { |r|
        Agent::HybridRetriever::Citation.new(
          host_id: r["host_id"], scanned_at: r["scanned_at"], source: r["source"] || "internal"
        )
      },
      warnings: [], retrieval_path: "graph", duration_ms: 5
    )
    Class.new {
      def initialize(r) = (@r = r)
      def call(_) = @r
    }.new(response)
  end

  before do
    Mcp::ToolRegistry.reset!
  end

  it "search_hosts propage source=\"nmap\" sur un host ingéré depuis un scanner externe" do
    rows = [{ "host_id" => "h1", "scanned_at" => "2026-05-01", "source" => "nmap" }]
    Mcp::CoreTools.register_all!(retriever: retriever_with(rows), scope_storage: scope_storage)

    tool = Mcp::ToolRegistry.fetch("search_hosts")
    result = tool.call(
      params:        { query: "x" },
      caller_id:     "x",
      caller_scopes: [:"read:hosts"]
    )
    expect(result[:rows].first["source"]).to eq("nmap")
  end

  it "search_hosts propage sources=[\"internal\",\"nmap\"] sur un host hybride" do
    rows = [{
      "host_id"  => "h2",
      "scanned_at" => "2026-05-01",
      "sources"  => %w[internal nmap]
    }]
    Mcp::CoreTools.register_all!(retriever: retriever_with(rows), scope_storage: scope_storage)

    tool = Mcp::ToolRegistry.fetch("search_hosts")
    result = tool.call(
      params:        { query: "x" },
      caller_id:     "x",
      caller_scopes: [:"read:hosts"]
    )
    expect(result[:rows].first["sources"]).to contain_exactly("internal", "nmap")
  end

  it "get_host renvoie le source de l'hôte trouvé" do
    rows = [{ "host_id" => "h3", "scanned_at" => "2026-05-01", "source" => "nuclei" }]
    Mcp::CoreTools.register_all!(retriever: retriever_with(rows), scope_storage: scope_storage)

    tool = Mcp::ToolRegistry.fetch("get_host")
    result = tool.call(
      params:        { host_id: "h3" },
      caller_id:     "x",
      caller_scopes: [:"read:hosts"]
    )
    expect(result[:found]).to be true
    expect(result[:host]["source"]).to eq("nuclei")
  end

  it "host auto-collecté porte source=\"internal\" par défaut" do
    rows = [{ "host_id" => "h4", "scanned_at" => "2026-05-01", "source" => "internal" }]
    Mcp::CoreTools.register_all!(retriever: retriever_with(rows), scope_storage: scope_storage)

    tool = Mcp::ToolRegistry.fetch("search_hosts")
    result = tool.call(
      params:        { query: "x" },
      caller_id:     "x",
      caller_scopes: [:"read:hosts"]
    )
    expect(result[:rows].first["source"]).to eq("internal")
  end
end
