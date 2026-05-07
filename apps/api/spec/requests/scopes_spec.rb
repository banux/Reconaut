# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Scopes endpoints", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }
  let(:audit)    { Agent::AuditRecorder::InMemoryRecorder.new }

  before do
    registry.scope_storage  = storage
    registry.audit_recorder = audit
  end

  after { Reconaut::Registry.reset! }

  describe "GET /scopes" do
    it "renvoie une liste vide pour viewer" do
      get "/scopes", headers: { "X-Reconaut-Role" => "viewer" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("scopes" => [])
    end

    it "renvoie les scopes existants" do
      storage.create(kind: "domain", value: "example.fr")
      get "/scopes", headers: { "X-Reconaut-Role" => "analyst" }
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:scopes].first[:value]).to eq("example.fr")
    end
  end

  describe "POST /scopes" do
    it "rejette analyst avec 403" do
      post "/scopes",
        params: { kind: "ip", value: "1.2.3.4" }.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "analyst" }
      expect(response).to have_http_status(:forbidden)
    end

    it "cree un scope pour admin (201) et ecrit l'audit" do
      post "/scopes",
        params: { kind: "ip", value: "1.2.3.4" }.to_json,
        headers: { "Content-Type" => "application/json",
                   "X-Reconaut-Role" => "admin",
                   "X-Reconaut-Caller" => "admin-1" }

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:scope][:kind]).to eq("ip")
      expect(body[:scope][:value]).to eq("1.2.3.4")
      expect(audit.entries.last[:status]).to eq(:success)
      expect(audit.entries.last[:caller_id]).to eq("admin-1")
    end

    it "renvoie 400 invalid_kind sur kind hors enum" do
      post "/scopes",
        params: { kind: "person", value: "alice" }.to_json,
        headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "owner" }

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to eq("error" => "invalid_kind")
    end
  end

  describe "DELETE /scopes/:id" do
    it "supprime et renvoie 204 pour owner" do
      scope = storage.create(kind: "ip", value: "1.2.3.4")
      delete "/scopes/#{scope.id}",
        headers: { "X-Reconaut-Role" => "owner" }

      expect(response).to have_http_status(:no_content)
      expect(storage.list).to be_empty
    end

    it "404 sur id inconnu" do
      delete "/scopes/nope",
        headers: { "X-Reconaut-Role" => "owner" }

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq("error" => "scope_not_found")
    end

    it "rejette viewer avec 403" do
      scope = storage.create(kind: "ip", value: "1.2.3.4")
      delete "/scopes/#{scope.id}",
        headers: { "X-Reconaut-Role" => "viewer" }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
