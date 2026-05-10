# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# Cf. openspec/changes/add-mcp-engine/specs/mcp-server/spec.md
#   -> Requirement: MCP Tool `export_report`

RSpec.describe "MCP export_report e2e", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }
  let(:tmpdir)   { Dir.mktmpdir("reconaut-export-spec") }

  let(:retriever) do
    Class.new {
      def call(_q)
        Agent::HybridRetriever::Response.new(
          rows: [], citations: [], warnings: [], retrieval_path: "graph", duration_ms: 1
        )
      end
    }.new
  end

  before do
    Mcp::ToolRegistry.reset!
    registry.scope_storage = storage
    ENV["RECONAUT_EXPORT_DIR"]  = tmpdir
    ENV["RECONAUT_EXPORT_TTL_S"] = "3600"
    Mcp::CoreTools.register_all!(
      retriever: retriever, scope_storage: storage,
      scan_enqueuer: registry.scan_enqueuer
    )
    # Seed minimal en base
    Host.delete_all
    Host.create!(ip: "192.0.2.10")
    Host.create!(fqdn: "mail.example.fr")
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
    FileUtils.rm_rf(tmpdir)
    ENV.delete("RECONAUT_EXPORT_DIR")
    ENV.delete("RECONAUT_EXPORT_TTL_S")
  end

  def request_export(format:, kind: "hosts", limit: 100)
    post "/mcp/tools/export_report",
         params: {
           filter: { kind: kind, limit: limit },
           format: format
         }.to_json,
         headers: { "Content-Type" => "application/json" }
  end

  describe "JSON" do
    it "200 + download_url + token + expires_at" do
      request_export(format: "json")
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      r = body[:result]
      expect(r[:download_url]).to match(%r{\A/mcp/exports/[0-9a-f-]{36}\?token=})
      expect(r[:token]).to match(/\A[0-9a-f]{64}\z/) # SHA-256 hex
      expect(r[:expires_at]).to match(/\A\d{4}-\d{2}-\d{2}T/)
      expect(r[:format]).to eq("json")
      expect(r[:record_count]).to eq(2)
    end

    it "GET /mcp/exports/:id?token=...&expires_at=... → 200 + JSON parseable" do
      request_export(format: "json")
      r = JSON.parse(response.body, symbolize_names: true)[:result]
      get r[:download_url]
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to include("application/json")
      parsed = JSON.parse(response.body)
      expect(parsed).to be_an(Array)
      expect(parsed.size).to eq(2)
    end
  end

  describe "one-shot download" do
    it "second download → 404" do
      request_export(format: "json")
      url = JSON.parse(response.body, symbolize_names: true)[:result][:download_url]

      get url
      expect(response).to have_http_status(:ok)

      get url
      expect(response).to have_http_status(:not_found)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:error]).to eq("not_found")
    end
  end

  describe "token altered" do
    it "404 (sans confirmer l'existence du fichier)" do
      request_export(format: "json")
      r = JSON.parse(response.body, symbolize_names: true)[:result]
      bad_url = r[:download_url].sub(/token=[0-9a-f]{64}/, "token=" + ("0" * 64))

      get bad_url
      expect(response).to have_http_status(:not_found)
      # Le fichier n'a pas été supprimé par la tentative malveillante
      uuid = r[:download_url].match(%r{exports/([0-9a-f-]{36})})[1]
      expect(Dir.glob(File.join(tmpdir, "#{uuid}.*"))).not_to be_empty
    end
  end

  describe "CSV format" do
    it "GET retourne text/csv avec headers RFC4180" do
      request_export(format: "csv")
      url = JSON.parse(response.body, symbolize_names: true)[:result][:download_url]
      get url
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to include("text/csv")
      expect(response.body.lines.first).to include("id,ip")
    end
  end

  describe "STIX2 format" do
    it "GET retourne application/stix+json + bundle valide" do
      request_export(format: "stix2")
      url = JSON.parse(response.body, symbolize_names: true)[:result][:download_url]
      get url
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to include("application/stix+json")
      bundle = JSON.parse(response.body)
      expect(bundle["type"]).to eq("bundle")
      expect(bundle["objects"]).to be_an(Array)
    end
  end

  describe "limit" do
    it "respecte le filter.limit" do
      request_export(format: "json", limit: 1)
      r = JSON.parse(response.body, symbolize_names: true)[:result]
      expect(r[:record_count]).to eq(1)
    end
  end

  describe "validation" do
    it "kind invalide → invalid_param" do
      request_export(format: "json", kind: "users")
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:ok]).to be false
      expect(body[:result][:error]).to eq("invalid_param")
    end

    it "format invalide → invalid_param" do
      post "/mcp/tools/export_report",
           params: { filter: { kind: "hosts" }, format: "yaml" }.to_json,
           headers: { "Content-Type" => "application/json" }
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:ok]).to be false
    end
  end
end
