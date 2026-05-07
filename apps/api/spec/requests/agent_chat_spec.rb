# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /agent/chat", type: :request do
  let(:audit) { Agent::AuditRecorder::InMemoryRecorder.new }
  let(:registry) { Reconaut::Registry.default }

  before do
    registry.audit_recorder = audit
    # Pipeline factice pour pouvoir tester le controller sans DB.
    response = Agent::HybridRetriever::Response.new(
      rows: [{ "host_id" => "h1", "scanned_at" => "2026-05-01" }],
      citations: [Agent::HybridRetriever::Citation.new(host_id: "h1", scanned_at: "2026-05-01")],
      warnings: [], retrieval_path: "graph", duration_ms: 30
    )
    registry.hybrid_retriever = Class.new {
      def initialize(r) = (@r = r)
      def call(_q) = @r
    }.new(response)
  end

  after do
    Reconaut::Registry.reset!
  end

  it "renvoie 200 + body conforme au contrat AgentClient pour un analyst" do
    post "/agent/chat",
      params: { query: "hotes nginx" }.to_json,
      headers: {
        "Content-Type"     => "application/json",
        "X-Reconaut-Role"  => "analyst",
        "X-Reconaut-Caller" => "user-42"
      }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body.keys).to contain_exactly(
      :rows, :citations, :warnings, :retrieval_path, :duration_ms
    )
    expect(body[:retrieval_path]).to eq("graph")
    expect(body[:rows].first[:host_id]).to eq("h1")
  end

  it "rejette viewer avec 403 + body { error: rbac_forbidden }" do
    post "/agent/chat",
      params: { query: "hotes" }.to_json,
      headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "viewer" }

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)).to eq("error" => "rbac_forbidden")
  end

  it "rejette une query vide avec 400 query_required" do
    post "/agent/chat",
      params: { query: "  " }.to_json,
      headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "analyst" }

    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body)).to eq("error" => "query_required")
  end

  it "renvoie 503 quand le pipeline graphe n'est pas cable" do
    registry.hybrid_retriever = nil

    post "/agent/chat",
      params: { query: "hotes" }.to_json,
      headers: { "Content-Type" => "application/json", "X-Reconaut-Role" => "analyst" }

    expect(response).to have_http_status(:service_unavailable)
    expect(JSON.parse(response.body)).to eq("error" => "agent_pipeline_unavailable")
  end

  it "ecrit une ligne d'audit success avec le caller_id" do
    post "/agent/chat",
      params: { query: "hi" }.to_json,
      headers: { "Content-Type" => "application/json",
                 "X-Reconaut-Role" => "owner",
                 "X-Reconaut-Caller" => "owner-1" }

    expect(audit.entries.last[:status]).to eq(:success)
    expect(audit.entries.last[:caller_id]).to eq("owner-1")
  end

  it "par defaut sans header de role, applique :viewer (donc 403)" do
    post "/agent/chat",
      params: { query: "hi" }.to_json,
      headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:forbidden)
  end
end
