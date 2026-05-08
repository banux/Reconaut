# frozen_string_literal: true

require "rails_helper"

# Couvre init-reconaut-platform 7.1 : "API rejette tout paramètre
# tenant_id ou header X-Tenant" et add-tech-stack architecture
# scenario "API rejette tout paramètre de tenant".
#
# Les anciens endpoints REST (/scopes, /agent/chat) ont été retirés
# par single-user-only / mcp-as-primary-entrypoint ; le contrôle vit
# désormais sur le canal MCP. On vérifie sur `POST /mcp/tools/:name`
# que le rejet tenant reste actif.
RSpec.describe "Tenant param rejection", type: :request do
  before do
    Reconaut::Registry.reset!
    Mcp::ToolRegistry.reset!
    storage = Reconaut::Registry.default.scope_storage
    response = Agent::HybridRetriever::Response.new(
      rows: [], citations: [], warnings: [], retrieval_path: "none", duration_ms: 0
    )
    retriever = Class.new {
      def initialize(r) = (@r = r)
      def call(_) = @r
    }.new(response)
    Mcp::CoreTools.register_all!(retriever: retriever, scope_storage: storage)
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  describe "via query/body param sur MCP" do
    it "POST /mcp/tools/list_scopes?tenant_id=x -> 400" do
      post "/mcp/tools/list_scopes", params: { tenant_id: "x" }.to_json,
        headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to eq("error" => "tenant_param_unsupported")
    end

    it "rejette aussi `tenant`, `caller_tenant`, `org_id`" do
      %w[tenant caller_tenant org_id].each do |param|
        post "/mcp/tools/list_scopes", params: { param => "x" }.to_json,
          headers: { "Content-Type" => "application/json" }
        expect(response).to have_http_status(:bad_request),
                            "expected 400 for param=#{param}, got #{response.status}"
      end
    end
  end

  describe "via header sur MCP" do
    it "X-Tenant -> 400" do
      post "/mcp/tools/list_scopes", params: {}.to_json,
        headers: { "Content-Type" => "application/json", "X-Tenant" => "acme" }
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to eq("error" => "tenant_param_unsupported")
    end

    it "X-Tenant-Id, X-Org, X-Org-Id sont aussi rejetés" do
      %w[X-Tenant-Id X-Org X-Org-Id].each do |h|
        post "/mcp/tools/list_scopes", params: {}.to_json,
          headers: { "Content-Type" => "application/json", h => "x" }
        expect(response).to have_http_status(:bad_request),
                            "expected 400 for header=#{h}"
      end
    end
  end

  describe "happy path (sans tenant)" do
    it "POST /mcp/tools/list_scopes sans champ tenant -> 200" do
      post "/mcp/tools/list_scopes", params: {}.to_json,
        headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
    end
  end
end
