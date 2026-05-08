# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/mcp/core_tools"

# Cf. openspec/changes/mcp-as-primary-entrypoint/tasks.md §5.5 et
# specs/architecture/spec.md (Requirement: Single API Key per Operator
# Across MCP Clients).
# Cf. openspec/changes/single-user-only/specs/architecture/spec.md
# (TUI et agent IA peuvent partager une même clé OU avoir des clés
# distinctes, chacune avec son propre set de scopes).
RSpec.describe "Single API key shared TUI / external AI agent", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:api_key_store) { registry.api_key_store }

  let(:retriever) do
    response = Agent::HybridRetriever::Response.new(
      rows: [{ "host_id" => "h1", "scanned_at" => "2026-05-01" }],
      citations: [], warnings: [], retrieval_path: "graph", duration_ms: 5
    )
    Class.new {
      def initialize(r) = (@r = r)
      def call(_) = @r
    }.new(response)
  end

  before do
    Mcp::CoreTools.register_all!(
      retriever:        retriever,
      scope_storage:    registry.scope_storage,
      scan_enqueuer:    registry.scan_enqueuer,
      api_key_storage:  api_key_store
    )
    registry.user_store.create(email: "ops@example.com", password_hash: "x")
    @record, @raw_token = api_key_store.create_for
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  it "la même clé sert TUI (reconautctl) et un agent IA pour invoquer un tool MCP" do
    post "/mcp/tools/search_hosts",
      params: { query: "modbus" }.to_json,
      headers: {
        "Content-Type"  => "application/json",
        "Authorization" => "Bearer #{@raw_token}",
        "User-Agent"    => "reconautctl/0.1.0"
      }
    expect(response).to have_http_status(:ok)

    post "/mcp/tools/search_hosts",
      params: { query: "siemens" }.to_json,
      headers: {
        "Content-Type"  => "application/json",
        "Authorization" => "Bearer #{@raw_token}",
        "User-Agent"    => "claude-sdk-mcp/1.2"
      }
    expect(response).to have_http_status(:ok)
  end

  it "la révocation MCP de la clé coupe simultanément les deux usages" do
    # Pré-condition : la clé fonctionne.
    post "/mcp/tools/search_hosts",
      params: { query: "x" }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{@raw_token}" }
    expect(response).to have_http_status(:ok)

    api_key_store.revoke!(@record.id)

    # Avec RECONAUT_REQUIRE_API_KEY=true, l'absence d'identité valide
    # entraîne caller_scopes = [], donc tout tool est rejeté.
    ENV["RECONAUT_REQUIRE_API_KEY"] = "true"
    begin
      post "/mcp/tools/search_hosts",
        params: { query: "x" }.to_json,
        headers: {
          "Content-Type"  => "application/json",
          "Authorization" => "Bearer #{@raw_token}",
          "User-Agent"    => "reconautctl/0.1.0"
        }
      expect(response).to have_http_status(:forbidden)

      post "/mcp/tools/add_scope",
        params: { kind: "ip", value: "192.0.2.1" }.to_json,
        headers: {
          "Content-Type"  => "application/json",
          "Authorization" => "Bearer #{@raw_token}",
          "User-Agent"    => "claude-sdk-mcp/1.2"
        }
      expect(response).to have_http_status(:forbidden)
    ensure
      ENV.delete("RECONAUT_REQUIRE_API_KEY")
    end
  end
end
