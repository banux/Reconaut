# frozen_string_literal: true

require "rails_helper"

# Couvre init-reconaut-platform 7.1 : "API rejette tout parametre
# tenant_id ou header X-Tenant" et add-tech-stack architecture
# scenario "API rejette tout parametre de tenant".

RSpec.describe "Tenant param rejection", type: :request do
  before { Reconaut::Registry.reset! }
  after  { Reconaut::Registry.reset! }

  describe "via query param" do
    it "GET /scopes?tenant_id=x -> 400 tenant_param_unsupported" do
      get "/scopes", params: { tenant_id: "x" },
                     headers: { "X-Reconaut-Role" => "viewer" }
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to eq("error" => "tenant_param_unsupported")
    end

    it "POST /agent/chat avec tenant_id dans le body -> 400" do
      post "/agent/chat",
        params: { query: "hi", tenant_id: "x" }.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "owner" }
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to eq("error" => "tenant_param_unsupported")
    end

    it "rejette aussi `tenant`, `caller_tenant`, `org_id`" do
      %w[tenant caller_tenant org_id].each do |param|
        get "/scopes", params: { param => "x" },
                       headers: { "X-Reconaut-Role" => "viewer" }
        expect(response).to have_http_status(:bad_request),
                            "expected 400 for param=#{param}, got #{response.status}"
      end
    end
  end

  describe "via header" do
    it "X-Tenant -> 400" do
      get "/scopes", headers: {
        "X-Reconaut-Role" => "viewer",
        "X-Tenant" => "acme"
      }
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to eq("error" => "tenant_param_unsupported")
    end

    it "X-Tenant-Id, X-Org, X-Org-Id sont aussi rejetes" do
      %w[X-Tenant-Id X-Org X-Org-Id].each do |h|
        get "/scopes", headers: { "X-Reconaut-Role" => "viewer", h => "x" }
        expect(response).to have_http_status(:bad_request),
                            "expected 400 for header=#{h}"
      end
    end
  end

  describe "happy path (sans tenant)" do
    it "GET /scopes sans aucun champ tenant -> 200" do
      get "/scopes", headers: { "X-Reconaut-Role" => "viewer" }
      expect(response).to have_http_status(:ok)
    end
  end
end
