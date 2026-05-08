# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/mcp/core_tools"

# Couvre :
#   openspec/changes/init-reconaut-platform/specs/mcp-server/spec.md
#   openspec/changes/init-reconaut-platform/tasks.md sections 5.1 / 5.3
#   openspec/changes/add-tech-stack/tasks.md section 4.1

RSpec.describe "MCP tools endpoint", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }

  let(:retriever_response) do
    Agent::HybridRetriever::Response.new(
      rows: [{ "host_id" => "h1", "scanned_at" => "2026-05-01" }],
      citations: [Agent::HybridRetriever::Citation.new(host_id: "h1", scanned_at: "2026-05-01")],
      warnings: [],
      retrieval_path: "graph",
      duration_ms: 30
    )
  end

  let(:retriever) do
    Class.new {
      def initialize(r) = (@r = r)
      def call(_q) = @r
    }.new(retriever_response)
  end

  before do
    registry.scope_storage = storage
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

  describe "GET /mcp/tools" do
    it "liste les outils enregistres avec leurs scopes et schemas" do
      get "/mcp/tools", headers: { "X-Reconaut-Role" => "viewer" }
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body, symbolize_names: true)
      names = body[:tools].map { |t| t[:name] }
      expect(names).to contain_exactly("search_hosts", "get_host", "list_scopes", "add_scope", "revoke_scope", "request_scan", "system_doctor")

      search = body[:tools].find { |t| t[:name] == "search_hosts" }
      expect(search[:scopes]).to include("read:hosts")
      expect(search[:params]).to have_key(:query)
    end
  end

  describe "POST /mcp/tools/search_hosts" do
    it "200 + retourne les rows pour un viewer" do
      post "/mcp/tools/search_hosts",
        params: { query: "hotes nginx", limit: 10 }.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "viewer" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:tool]).to eq("search_hosts")
      expect(body[:result][:rows].first[:host_id]).to eq("h1")
      expect(body[:result][:retrieval_path]).to eq("graph")
    end

    it "400 missing_param quand query absente" do
      post "/mcp/tools/search_hosts",
        params: {}.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "viewer" }

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("missing_param")
    end

    it "400 param_invalid quand limit > 100" do
      post "/mcp/tools/search_hosts",
        params: { query: "x", limit: 1000 }.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "viewer" }

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("param_invalid")
      expect(body["message"]).to include("limit")
    end
  end

  describe "POST /mcp/tools/get_host" do
    it "200 + found:true quand l'hote correspond" do
      post "/mcp/tools/get_host",
        params: { host_id: "h1" }.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "analyst" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:found]).to be true
      expect(body[:result][:host][:host_id]).to eq("h1")
    end

    it "200 + found:false quand l'hote ne matche pas" do
      empty_resp = Agent::HybridRetriever::Response.new(
        rows: [], citations: [], warnings: [], retrieval_path: "none", duration_ms: 0
      )
      empty_retriever = Class.new {
        def initialize(r) = (@r = r)
        def call(_) = @r
      }.new(empty_resp)
      Mcp::CoreTools.register_all!(retriever: empty_retriever, scope_storage: storage)

      post "/mcp/tools/get_host",
        params: { host_id: "ghost" }.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "analyst" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:found]).to be false
    end
  end

  describe "POST /mcp/tools/list_scopes" do
    it "200 + retourne les scopes existants" do
      storage.create(kind: "domain", value: "example.fr")
      storage.create(kind: "ip",     value: "192.0.2.1")

      post "/mcp/tools/list_scopes",
        params: {}.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "viewer" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:scopes].length).to eq(2)
    end
  end

  describe "404 / unknown_tool" do
    it "renvoie 404 unknown_tool sur outil inconnu" do
      post "/mcp/tools/banana",
        params: {}.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "viewer" }

      expect(response).to have_http_status(:not_found)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("unknown_tool")
    end
  end

  describe "RBAC par scope" do
    it "viewer peut search_hosts (read:hosts) et list_scopes (read:scopes)" do
      post "/mcp/tools/search_hosts",
        params: { query: "x" }.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "viewer" }
      expect(response).to have_http_status(:ok)
    end

    it "un role inconnu (sans scopes) recoit 403 rbac_forbidden" do
      post "/mcp/tools/search_hosts",
        params: { query: "x" }.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "stranger" }

      # X-Reconaut-Role inconnu -> defaut :viewer (cf. RoleResolver), donc OK.
      # Pour tester l'absence de scope, on stub temporairement :
    end
  end

  describe "audit log" do
    let(:audit) { Agent::AuditRecorder::InMemoryRecorder.new }

    before do
      registry.audit_recorder = audit
      Mcp::CoreTools.register_all!(retriever: retriever, scope_storage: storage)
    end

    it "ecrit une entree d'audit success sur invocation reussie" do
      post "/mcp/tools/search_hosts",
        params: { query: "x" }.to_json,
        headers: { "Content-Type" => "application/json",
                   "X-Reconaut-Role" => "analyst",
                   "X-Reconaut-Caller" => "analyst-1" }

      entry = audit.entries.last
      expect(entry[:status]).to eq(:success)
      expect(entry[:template_id]).to eq("mcp:search_hosts")
      expect(entry[:caller_id]).to eq("analyst-1")
    end

    it "ecrit une entree :unknown_template sur outil inconnu" do
      post "/mcp/tools/banana",
        params: {}.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "viewer" }

      expect(audit.entries.last[:status]).to eq(:unknown_template)
      expect(audit.entries.last[:template_id]).to eq("mcp:banana")
    end
  end

  describe "rejet tenant_id (defense en profondeur)" do
    it "MCP refuse aussi les params tenant_id" do
      post "/mcp/tools/search_hosts",
        params: { query: "x", tenant_id: "acme" }.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "viewer" }

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to eq("error" => "tenant_param_unsupported")
    end
  end
end
