# frozen_string_literal: true

require "rails_helper"
require "net/http"

RSpec.describe "/auth/api_keys", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let!(:user) do
    registry.user_store.create(
      email: "owner@reconaut.local",
      password_hash: registry.password_hasher.hash("hunter2"),
      role: :owner
    )
  end
  let!(:bootstrap_token) do
    registry.authenticator.issue_api_key(user_id: user.id)[:token]
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
    end
  end

  describe "GET" do
    it "liste les cles du user (sans token, sans token_hash)" do
      get "/auth/api_keys",
        headers: { "Authorization" => "Bearer #{bootstrap_token}" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:api_keys].first.keys).to contain_exactly(:id, :user_id, :prefix, :created_at, :revoked_at)
    end
  end

  describe "DELETE" do
    it "revoque une cle existante (204) et la rend inutilisable" do
      key = registry.api_key_store.list_for(user.id).first

      delete "/auth/api_keys/#{key.id}",
        headers: { "Authorization" => "Bearer #{bootstrap_token}" }

      expect(response).to have_http_status(:no_content)

      # Deuxieme requete avec le meme token -> 401 (cle revoquee).
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

  describe "Bearer + RBAC propage le role du user authentifie" do
    it "Bearer owner -> /scopes en lecture OK" do
      get "/scopes",
        headers: { "Authorization" => "Bearer #{bootstrap_token}" }
      expect(response).to have_http_status(:ok)
    end

    it "Bearer owner peut creer un scope (scope mutation)" do
      post "/scopes",
        params: { kind: "ip", value: "192.0.2.1" }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{bootstrap_token}"
        }
      expect(response).to have_http_status(:created)
    end

    # En mode mono-user (single-user-only), tout opérateur authentifié
    # est :operator et peut muter le scope. Le test « viewer ne peut
    # pas muter » a perdu son objet — la défense-en-profondeur passe
    # désormais par les scopes attachés à chaque clé API, pas par un
    # role différent. Test réécrit pour confirmer que tout user
    # authentifié peut créer un scope.
    it "Bearer operator peut creer un scope (tout user authentifie est :operator)" do
      second = registry.user_store.create(
        email: "second@reconaut.local",
        password_hash: registry.password_hasher.hash("p")
      )
      second_token = registry.authenticator.issue_api_key(user_id: second.id)[:token]

      post "/scopes",
        params: { kind: "ip", value: "198.51.100.1" }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{second_token}"
        }
      expect(response).to have_http_status(:created)
    end
  end

  describe "scenario bootstrap : aucune connexion sortante" do
    # Materialise le test plan 7.2 (a) : "bootstrap sans config OIDC,
    # creation d'un compte owner local, generation de cle API, appel
    # API + MCP ; assurer zero connexion sortante".
    it "stub Net::HTTP.start pour exploser ; le flow auth + API + MCP passe sans appel reseau" do
      allow(Net::HTTP).to receive(:start).and_raise("network forbidden in air-gapped scenario")

      # 1. Creer un compte
      bootstrap_user = registry.user_store.create(
        email: "air-gapped@local",
        password_hash: registry.password_hasher.hash("p")
      )
      # 2. Issuer une cle API
      issued = registry.authenticator.issue_api_key(user_id: bootstrap_user.id)
      bearer = "Bearer #{issued[:token]}"

      # 3. Appel API REST (scopes liste)
      get "/scopes", headers: { "Authorization" => bearer }
      expect(response).to have_http_status(:ok)

      # 4. Appel MCP (list_scopes)
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
