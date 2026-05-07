# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/use_cases/scopes/operations"
require_relative "../../../app/lib/agent/audit_recorder"

RSpec.describe "Scopes use cases" do
  let(:storage) { Scopes::Storage::InMemory.new }
  let(:audit)   { Agent::AuditRecorder::InMemoryRecorder.new }

  describe Scopes::UseCases::List do
    subject(:use_case) { described_class.new(storage: storage) }

    %i[viewer analyst admin owner].each do |role|
      it "autorise #{role} en lecture" do
        result = use_case.call(caller_role: role)
        expect(result.status).to eq(:ok)
        expect(result.body[:scopes]).to eq([])
      end
    end

    it "rejette un role inconnu (ex. :stranger) avec 403" do
      result = use_case.call(caller_role: :stranger)
      expect(result.status).to eq(:unauthorized)
    end

    it "renvoie les scopes presents" do
      storage.create(kind: "domain", value: "a.fr")
      result = use_case.call(caller_role: :analyst)
      expect(result.body[:scopes].length).to eq(1)
      expect(result.body[:scopes].first).to include(:id, :kind, :value, :created_at)
    end
  end

  describe Scopes::UseCases::Add do
    subject(:use_case) { described_class.new(storage: storage, audit_recorder: audit) }

    %i[viewer analyst].each do |role|
      it "rejette #{role} (lecture seule cote scope)" do
        result = use_case.call(kind: "ip", value: "1.2.3.4", caller_role: role)
        expect(result.status).to eq(:unauthorized)
        expect(audit.entries.last[:status]).to eq(:unauthorized)
      end
    end

    it "autorise admin a creer + audit success" do
      result = use_case.call(kind: "ip", value: "1.2.3.4", caller_role: :admin, caller_id: "u-1")
      expect(result.status).to eq(:created)
      expect(result.http_status).to eq(201)
      expect(result.body[:scope][:value]).to eq("1.2.3.4")

      entry = audit.entries.last
      expect(entry[:status]).to eq(:success)
      expect(entry[:caller_id]).to eq("u-1")
      expect(entry[:params_normalized][:action]).to eq("create")
    end

    it "renvoie 400 + audit param_invalid quand kind hors enum" do
      result = use_case.call(kind: "person", value: "alice", caller_role: :owner)
      expect(result.status).to eq(:bad_request)
      expect(result.body[:error]).to eq("invalid_kind")
      expect(audit.entries.last[:status]).to eq(:param_invalid)
    end

    it "renvoie 400 + audit param_invalid quand value vide" do
      result = use_case.call(kind: "ip", value: "", caller_role: :owner)
      expect(result.status).to eq(:bad_request)
      expect(result.body[:error]).to eq("value_required")
    end
  end

  describe Scopes::UseCases::Revoke do
    subject(:use_case) { described_class.new(storage: storage, audit_recorder: audit) }

    it "rejette analyst (write reserve a admin/owner)" do
      scope = storage.create(kind: "ip", value: "1.2.3.4")
      result = use_case.call(id: scope.id, caller_role: :analyst)
      expect(result.status).to eq(:unauthorized)
    end

    it "renvoie 404 sur id inconnu (sous role autorise) + audit param_invalid" do
      result = use_case.call(id: "nope", caller_role: :owner)
      expect(result.status).to eq(:not_found)
      expect(result.body[:error]).to eq("scope_not_found")
      expect(audit.entries.last[:status]).to eq(:param_invalid)
    end

    it "supprime le scope et renvoie 204 + audit success" do
      scope = storage.create(kind: "ip", value: "1.2.3.4")
      result = use_case.call(id: scope.id, caller_role: :owner, caller_id: "owner-1")
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
