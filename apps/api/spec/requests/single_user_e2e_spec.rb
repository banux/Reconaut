# frozen_string_literal: true

require "rails_helper"

# E2e mono-user (cf. openspec/changes/single-user-only/tasks.md §7.3) :
# `set_password` -> `login` (password seul) -> clé full-scope ->
# invocation de trois outils MCP -> success. Plus aucun endpoint
# multi-user.
RSpec.describe "Single-user e2e", type: :request do
  let(:registry) { Reconaut::Registry.default }

  before do
    registry.password_hasher = Reconaut::Auth::PasswordHasher::Plain.new
    Reconaut::Auth::Bootstrap.call(password: "hunter2", registry: registry)

    Mcp::CoreTools.register_all!(
      retriever: Class.new {
        def call(_) = Agent::HybridRetriever::Response.new(
          rows: [{ "host_id" => "h1", "scanned_at" => "2026-05-01" }],
          citations: [Agent::HybridRetriever::Citation.new(host_id: "h1", scanned_at: "2026-05-01")],
          warnings: [], retrieval_path: "graph", duration_ms: 5
        )
      }.new,
      scope_storage:   registry.scope_storage,
      scan_enqueuer:   registry.scan_enqueuer,
      api_key_storage: registry.api_key_store,
      heartbeat_store: registry.heartbeat_store
    )
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  it "login (password seul) puis trois invocations MCP réussissent avec la même clé" do
    # 1. Login : password seul → clé full-scope
    post "/auth/sessions",
      params:  { password: "hunter2" }.to_json,
      headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:created)

    body = JSON.parse(response.body, symbolize_names: true)
    token = body[:api_key][:token]
    expect(body[:api_key][:scopes]).to include("read:hosts", "write:scopes", "read:health")

    bearer = "Bearer #{token}"

    # 2. Invocation #1 : list_scopes
    post "/mcp/tools/list_scopes", params: {}.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => bearer }
    expect(response).to have_http_status(:ok)

    # 3. Invocation #2 : search_hosts
    post "/mcp/tools/search_hosts", params: { query: "x" }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => bearer }
    expect(response).to have_http_status(:ok)

    # 4. Invocation #3 : system_doctor
    post "/mcp/tools/system_doctor", params: {}.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => bearer }
    expect(response).to have_http_status(:ok)
  end

  it "aucun endpoint REST multi-user n'existe (création d'un second user)" do
    post "/users", params: { email: "second@x" }.to_json,
      headers: { "Content-Type" => "application/json" }
    # Routes Rails par défaut : 404 sur route inconnue.
    expect(response.status).to eq(404).or eq(400)
  end
end
