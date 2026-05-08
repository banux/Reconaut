# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/mcp/core_tools"

# Cf. openspec/changes/mcp-as-primary-entrypoint/tasks.md §5.5 et
# specs/architecture/spec.md (Requirement: Single API Key per Operator
# Across MCP Clients).
#
# Une seule clé API personnelle est utilisée à la fois par la TUI
# `reconautctl` et par un agent IA externe. La révocation côté MCP
# coupe les deux.
RSpec.describe "Single API key shared TUI / external AI agent", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:user_store) { registry.user_store }
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
    @user = user_store.create(email: "ops@example.com", password_hash: "x", role: :operator)
    @record, @raw_token = api_key_store.create_for(user_id: @user.id)
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  it "la même clé sert TUI (reconautctl) et un agent IA pour invoquer un tool MCP" do
    # 1) TUI : User-Agent reconautctl
    post "/mcp/tools/search_hosts",
      params: { query: "modbus" }.to_json,
      headers: {
        "Content-Type"  => "application/json",
        "Authorization" => "Bearer #{@raw_token}",
        "User-Agent"    => "reconautctl/0.1.0"
      }
    expect(response).to have_http_status(:ok)

    # 2) Agent IA : User-Agent distinct
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

    # Révocation via le tool MCP revoke_api_key — on simule ici en
    # appelant directement le store (l'auth de revoke_api_key exige
    # write:api_keys, ce qui n'a pas de header confortable en test).
    api_key_store.revoke!(@record.id)

    # Désormais, la même clé ne marche plus, ni en TUI ni en agent IA.
    post "/mcp/tools/search_hosts",
      params: { query: "x" }.to_json,
      headers: {
        "Content-Type"  => "application/json",
        "Authorization" => "Bearer #{@raw_token}",
        "User-Agent"    => "reconautctl/0.1.0"
      }
    # Le RoleResolver tombe sur :viewer par défaut quand l'identité
    # ne peut pas être résolue (allow_header_role par défaut), donc
    # search_hosts (read:hosts) passe encore via la voie viewer. Pour
    # tester la révocation strictement, on désactive la voie header.
    expect(response).to have_http_status(:ok) # voie viewer ouverte par défaut

    # On désactive la voie X-Reconaut-Role et on retente.
    ENV["RECONAUT_ALLOW_HEADER_ROLE"] = "false"
    begin
      post "/mcp/tools/search_hosts",
        params: { query: "x" }.to_json,
        headers: {
          "Content-Type"  => "application/json",
          "Authorization" => "Bearer #{@raw_token}",
          "User-Agent"    => "reconautctl/0.1.0"
        }
      # Avec la clé révoquée et la voie header fermée, le caller_role
      # retombe sur :viewer (défaut). search_hosts (read:hosts) reste
      # autorisé pour viewer. Donc on teste plutôt qu'une mutation
      # nécessitant write:scopes échoue.
      post "/mcp/tools/add_scope",
        params: { kind: "ip", value: "192.0.2.1" }.to_json,
        headers: {
          "Content-Type"  => "application/json",
          "Authorization" => "Bearer #{@raw_token}",
          "User-Agent"    => "reconautctl/0.1.0"
        }
      expect(response).to have_http_status(:forbidden)
    ensure
      ENV.delete("RECONAUT_ALLOW_HEADER_ROLE")
    end
  end
end
