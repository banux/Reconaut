# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# Cf. openspec/changes/add-mcp-engine/specs/mcp-server/spec.md
#   -> Requirement: All Five Listed Tools Reachable via HTTP+SSE
#
# Vérifie que les 5 tools listés par init-reconaut-platform §5.1
# (`search_hosts`, `get_host`, `request_scan`, `get_scan_status`,
# `export_report`) sont enregistrés ET accessibles via HTTP.

RSpec.describe "MCP engine — les 5 tools de §5.1", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }
  let(:tmpdir)   { Dir.mktmpdir("reconaut-five-tools") }

  let(:retriever) do
    Class.new {
      def call(_q)
        Agent::HybridRetriever::Response.new(
          rows: [{ "host_id" => "h1", "scanned_at" => "2026-05-01" }],
          citations: [Agent::HybridRetriever::Citation.new(host_id: "h1", scanned_at: "2026-05-01")],
          warnings: [], retrieval_path: "graph", duration_ms: 1
        )
      end
    }.new
  end

  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.connection.execute("SELECT 1")
      unless ActiveRecord::Base.connection.table_exists?(:hosts)
        @skip = "Table hosts absente — lance `RAILS_ENV=test bundle exec rails db:migrate`"
      end
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before do
    skip(@skip) if @skip
    Mcp::ToolRegistry.reset!
    registry.scope_storage = storage
    storage.create(kind: "ip", value: "192.0.2.10")
    ENV["RECONAUT_EXPORT_DIR"]  = tmpdir
    ENV["RECONAUT_EXPORT_TTL_S"] = "3600"
    Mcp::CoreTools.register_all!(
      retriever: retriever, scope_storage: storage,
      scan_enqueuer: registry.scan_enqueuer,
      scan_store:    registry.scan_store
    )
    Host.delete_all
    @host = Host.create!(ip: "192.0.2.10")
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
    FileUtils.rm_rf(tmpdir)
    ENV.delete("RECONAUT_EXPORT_DIR")
    ENV.delete("RECONAUT_EXPORT_TTL_S")
  end

  it "GET /mcp/tools liste les 5 tools" do
    get "/mcp/tools"
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body, symbolize_names: true)
    names = body[:tools].map { |t| t[:name] }
    expect(names).to include(
      "search_hosts", "get_host", "request_scan", "get_scan_status", "export_report"
    )
  end

  it "search_hosts répond 200 sur HTTP" do
    post "/mcp/tools/search_hosts",
         params: { query: "modbus", limit: 5 }.to_json,
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:tool]).to eq("search_hosts")
  end

  it "get_host répond 200 sur HTTP" do
    post "/mcp/tools/get_host",
         params: { host_id: @host.id }.to_json,
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:tool]).to eq("get_host")
  end

  it "request_scan répond 200 sur HTTP" do
    post "/mcp/tools/request_scan",
         params: {
           scan_kind: "tcp_probe",
           target_kind: "ip",
           target_value: "192.0.2.10"
         }.to_json,
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:tool]).to eq("request_scan")
  end

  it "get_scan_status répond 200 sur HTTP" do
    post "/mcp/tools/get_scan_status",
         params: { scan_id: "scan-doesnt-exist" }.to_json,
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:tool]).to eq("get_scan_status")
  end

  it "export_report répond 200 sur HTTP avec download_url + token" do
    post "/mcp/tools/export_report",
         params: {
           filter: { kind: "hosts", limit: 10 },
           format: "json"
         }.to_json,
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:tool]).to eq("export_report")
    expect(body[:result][:download_url]).to match(%r{/mcp/exports/[0-9a-f-]{36}})
    expect(body[:result][:token]).to match(/\A[0-9a-f]{64}\z/)
  end

  it "purge_older_than! supprime les fichiers anciens à chaque export" do
    old_file = File.join(tmpdir, "old.json")
    File.write(old_file, "[]")
    File.utime(Time.now - 25 * 3600, Time.now - 25 * 3600, old_file)

    post "/mcp/tools/export_report",
         params: { filter: { kind: "hosts" }, format: "json" }.to_json,
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)

    expect(File.exist?(old_file)).to be false
  end
end
