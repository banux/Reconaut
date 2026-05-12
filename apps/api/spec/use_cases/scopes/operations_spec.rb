# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/use_cases/scopes/list"
require_relative "../../../app/use_cases/scopes/add"
require_relative "../../../app/use_cases/scopes/revoke"
require_relative "../../../app/lib/agent/audit_recorder"

# En mode mono-user (cf. openspec/changes/single-user-only/), les use
# cases ne portent plus de contrôle de rôle. Le contrôle d'accès vit
# dans les scopes attachés à la clé API courante (consommés par le
# tool MCP via Mcp::Tool#call). Ces specs valident donc le contrat
# fonctionnel : le use case écrit, lit, supprime — sans plus jamais
# rendre :unauthorized.
RSpec.describe "Scopes use cases" do
  let(:storage) { Scopes::Storage::InMemory.new }
  let(:audit)   { Agent::AuditRecorder::InMemoryRecorder.new }

  describe Scopes::List do
    subject(:use_case) { described_class.new(storage: storage) }

    it "lit la liste des scopes" do
      result = use_case.call
      expect(result.status).to eq(:ok)
      expect(result.body[:scopes]).to eq([])
    end

    it "renvoie les scopes présents" do
      storage.create(kind: "domain", value: "a.fr")
      result = use_case.call
      expect(result.body[:scopes].length).to eq(1)
      expect(result.body[:scopes].first).to include(:id, :kind, :value, :created_at)
    end
  end

  describe Scopes::Add do
    subject(:use_case) { described_class.new(storage: storage, audit_recorder: audit) }

    it "crée un scope + audit success" do
      result = use_case.call(kind: "ip", value: "1.2.3.4", caller_id: "key:abc")
      expect(result.status).to eq(:created)
      expect(result.http_status).to eq(201)
      expect(result.body[:scope][:value]).to eq("1.2.3.4")

      entry = audit.entries.last
      expect(entry[:status]).to eq(:success)
      expect(entry[:caller_id]).to eq("key:abc")
      expect(entry[:params_normalized][:action]).to eq("create")
    end

    it "renvoie 400 + audit param_invalid quand kind hors enum" do
      result = use_case.call(kind: "person", value: "alice")
      expect(result.status).to eq(:bad_request)
      expect(result.body[:error]).to eq("invalid_kind")
      expect(audit.entries.last[:status]).to eq(:param_invalid)
    end

    it "renvoie 400 + audit param_invalid quand value vide" do
      result = use_case.call(kind: "ip", value: "")
      expect(result.status).to eq(:bad_request)
      expect(result.body[:error]).to eq("value_required")
    end
  end

  describe Scopes::Revoke do
    subject(:use_case) { described_class.new(storage: storage, audit_recorder: audit) }

    it "renvoie 404 sur id inconnu + audit param_invalid" do
      result = use_case.call(id: "nope")
      expect(result.status).to eq(:not_found)
      expect(result.body[:error]).to eq("scope_not_found")
      expect(audit.entries.last[:status]).to eq(:param_invalid)
    end

    it "supprime le scope et renvoie 204 + audit success" do
      scope = storage.create(kind: "ip", value: "1.2.3.4")
      result = use_case.call(id: scope.id, caller_id: "key:owner")
      expect(result.status).to eq(:no_content)
      expect(result.http_status).to eq(204)
      expect(result.body).to be_nil
      expect(storage.list).to be_empty

      entry = audit.entries.last
      expect(entry[:status]).to eq(:success)
      expect(entry[:params_normalized][:action]).to eq("revoke")
      expect(entry[:params_normalized][:scope_id]).to eq(scope.id)
    end
  end
end
