# frozen_string_literal: true

require "rails_helper"
require "net/http"

# Cf. openspec/changes/single-user-only/specs/platform/spec.md.
# Routes /auth/* : auth bootstrap REST (login + génération/révocation
# de clé API). Tout le reste passe par MCP.
RSpec.describe "/auth/api_keys", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let!(:user) do
    registry.user_store.create(
      email: "operator@reconaut.local",
      password_hash: registry.password_hasher.hash("hunter2")
    )
  end
  let!(:bootstrap_token) do
    registry.authenticator.issue_api_key[:token]
  end

  after { Reconaut::Registry.reset! }

  describe "POST" do
    it "401 sans Authorization" do
      post "/auth/api_keys", params: {}.to_json,
                              headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to eq("error" => "auth_required")
    end

    it "201 + token avec une Authorization Bearer valide" do
      post "/auth/api_keys", params: {}.to_json,
                              headers: {
                                "Content-Type" => "application/json",
                                "Authorization" => "Bearer #{bootstrap_token}"
                              }
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:api_key][:token]).to be_a(String)
      expect(body[:api_key][:prefix]).to be_a(String)
      expect(body[:api_key][:scopes]).to be_an(Array)
    end

    it "201 + clé scopée quand `scopes:` est fourni dans le body" do
      post "/auth/api_keys",
        params:  { scopes: ["read:hosts", "read:scans"] }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{bootstrap_token}"
        }
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:api_key][:scopes]).to eq(%w[read:hosts read:scans])
    end
  end

  describe "GET" do
    it "liste les clés (sans token, sans token_hash)" do
      get "/auth/api_keys",
        headers: { "Authorization" => "Bearer #{bootstrap_token}" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:api_keys].first.keys).to contain_exactly(:id, :user_id, :prefix, :scopes, :created_at, :revoked_at)
    end
  end

  describe "DELETE" do
    it "révoque une clé existante (204) et la rend inutilisable" do
      key = registry.api_key_store.list.first

      delete "/auth/api_keys/#{key.id}",
        headers: { "Authorization" => "Bearer #{bootstrap_token}" }

      expect(response).to have_http_status(:no_content)

      # Deuxième requête avec le même token -> 401 (clé révoquée).
      get "/auth/api_keys",
        headers: { "Authorization" => "Bearer #{bootstrap_token}" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "404 sur id inconnu" do
      delete "/auth/api_keys/nope",
        headers: { "Authorization" => "Bearer #{bootstrap_token}" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "scenario bootstrap : aucune connexion sortante" do
    # Materialise le test plan : bootstrap d'une instance sans dépendance
    # externe (pas d'OIDC, pas d'IdP, pas d'embedder cloud), création
    # d'un compte opérateur local, génération de clé API, appel MCP ;
    # zéro connexion sortante.
    it "stub Net::HTTP.start pour exploser ; le flow passe sans appel réseau" do
      allow(Net::HTTP).to receive(:start).and_raise("network forbidden in air-gapped scenario")

      issued = registry.authenticator.issue_api_key
      bearer = "Bearer #{issued[:token]}"

      # Appel MCP (list_scopes)
      Mcp::CoreTools.register_all!(
        retriever: Class.new {
          def call(_) = Agent::HybridRetriever::Response.new(
            rows: [], citations: [], warnings: [],
            retrieval_path: "none", duration_ms: 0
          )
        }.new,
        scope_storage: registry.scope_storage,
        scan_enqueuer: registry.scan_enqueuer
      )
      post "/mcp/tools/list_scopes",
        params: {}.to_json,
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => bearer
        }
      expect(response).to have_http_status(:ok)

      Mcp::ToolRegistry.reset!
    end
  end
end
