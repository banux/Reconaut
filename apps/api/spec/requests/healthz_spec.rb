# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
# Scenario: Healthcheck non authentifié reste accessible.
RSpec.describe "GET /healthz", type: :request do
  let(:audit) { Agent::AuditRecorder::InMemoryRecorder.new }

  before do
    Reconaut::Registry.default.audit_recorder = audit
  end

  after { Reconaut::Registry.reset! }

  it "renvoie 200 + {\"status\":\"ok\"} sans header d'auth" do
    get "/healthz"
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body).to eq("status" => "ok")
  end

  it "n'écrit aucune ligne d'audit" do
    audit.clear! if audit.respond_to?(:clear!)
    expect {
      get "/healthz"
    }.not_to change { audit.entries.size }
  end
end
