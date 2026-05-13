# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/use_cases/scanner/claim_job"
require_relative "../../../app/use_cases/scopes/storage"
require_relative "../../../app/lib/agent/audit_recorder"

# Cf. openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
#   -> Requirement: MCP Tool `claim_scan_job`

RSpec.describe Scanner::ClaimJob do
  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.connection.execute("SELECT 1")
      unless ActiveRecord::Base.connection.table_exists?(:good_jobs)
        @skip = "Table good_jobs absente — GoodJob install non joué dans cet env de test"
      end
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before(:each) do
    skip(@skip) if @skip
    ActiveRecord::Base.connection.execute("DELETE FROM good_jobs")
  end

  let(:scope_storage) { Scopes::Storage::InMemory.new }
  let(:audit) { Agent::AuditRecorder::InMemoryRecorder.new }
  let(:clock) { -> { Time.utc(2026, 5, 13, 12, 0, 0) } }

  subject(:use_case) { described_class.new(scope_storage: scope_storage, audit_recorder: audit, clock: clock) }

  def insert_good_job(id:, queue:, payload:, performed_at: nil, finished_at: nil)
    ActiveRecord::Base.connection.execute(<<~SQL)
      INSERT INTO good_jobs (id, queue_name, serialized_params, created_at, updated_at, performed_at, finished_at)
      VALUES (
        '#{id}',
        '#{queue}',
        '#{ActiveRecord::Base.connection.quote_string(payload.to_json).gsub("'", "''")}',
        NOW(),
        NOW(),
        #{performed_at ? "'#{performed_at.iso8601}'" : 'NULL'},
        #{finished_at ? "'#{finished_at.iso8601}'" : 'NULL'}
      )
    SQL
  end

  describe "scope claim (target in scope)" do
    before do
      scope_storage.create(kind: "domain", value: "example.fr")
      insert_good_job(
        id: SecureRandom.uuid,
        queue: "scan:dns_records",
        payload: { "arguments" => [{ "target" => { "kind" => "domain", "value" => "example.fr" }, "scan_kind" => "dns_records" }] }
      )
    end

    it "retourne le job avec lease_until et set performed_at" do
      result = use_case.call(queue: "scan:dns_records", worker_id: "w-1", caller_id: "key:abc")
      expect(result.status).to eq(:ok)
      expect(result.body[:empty]).to be false
      expect(result.body[:job][:id]).to be_a(String)
      expect(result.body[:job][:lease_until]).to match(/\A2026-05-13T12:05:00/)
      expect(result.body[:job][:params]).to include("target" => { "kind" => "domain", "value" => "example.fr" })

      # performed_at mis à jour côté DB.
      row = ActiveRecord::Base.connection.execute("SELECT performed_at FROM good_jobs LIMIT 1").to_a.first
      expect(row["performed_at"]).not_to be_nil

      expect(audit.entries.last[:status]).to eq(:success)
      expect(audit.entries.last[:params_normalized][:outcome]).to eq("claimed")
    end
  end

  describe "file vide" do
    it "retourne empty:true" do
      result = use_case.call(queue: "scan:dns_records", worker_id: "w-1")
      expect(result.status).to eq(:ok)
      expect(result.body[:empty]).to be true
    end
  end

  describe "target hors scope" do
    before do
      scope_storage.create(kind: "domain", value: "other.fr")
      insert_good_job(
        id: SecureRandom.uuid,
        queue: "scan:dns_records",
        payload: { "arguments" => [{ "target" => { "kind" => "domain", "value" => "example.fr" }, "scan_kind" => "dns_records" }] }
      )
    end

    it "marque finished_at + error=out-of-scope et retourne empty:true" do
      result = use_case.call(queue: "scan:dns_records", worker_id: "w-1")
      expect(result.body[:empty]).to be true

      row = ActiveRecord::Base.connection.execute("SELECT finished_at, error FROM good_jobs LIMIT 1").to_a.first
      expect(row["finished_at"]).not_to be_nil
      expect(row["error"]).to eq("out-of-scope")

      expect(audit.entries.last[:params_normalized][:outcome]).to eq("out-of-scope")
    end
  end

  describe "lease expiré → re-claimable" do
    before do
      scope_storage.create(kind: "domain", value: "example.fr")
      insert_good_job(
        id: SecureRandom.uuid,
        queue: "scan:dns_records",
        payload: { "arguments" => [{ "target" => { "kind" => "domain", "value" => "example.fr" }, "scan_kind" => "dns_records" }] },
        performed_at: Time.utc(2026, 5, 13, 11, 0, 0) # 1h dans le passé
      )
    end

    it "claim retourne le job (filter lease)" do
      result = use_case.call(queue: "scan:dns_records", worker_id: "w-2", lease_seconds: 300)
      expect(result.body[:empty]).to be false
    end
  end

  describe "lease non encore expiré → empty" do
    before do
      scope_storage.create(kind: "domain", value: "example.fr")
      insert_good_job(
        id: SecureRandom.uuid,
        queue: "scan:dns_records",
        payload: { "arguments" => [{ "target" => { "kind" => "domain", "value" => "example.fr" }, "scan_kind" => "dns_records" }] },
        performed_at: Time.utc(2026, 5, 13, 11, 59, 0) # 1 minute dans le passé, lease 300s → encore actif
      )
    end

    it "ne re-claim PAS un job avec lease actif" do
      result = use_case.call(queue: "scan:dns_records", worker_id: "w-3", lease_seconds: 300)
      expect(result.body[:empty]).to be true
    end
  end

  describe "filtre par queue" do
    before do
      scope_storage.create(kind: "domain", value: "example.fr")
      insert_good_job(
        id: SecureRandom.uuid, queue: "scan:other_kind",
        payload: { "arguments" => [{ "target" => { "kind" => "domain", "value" => "example.fr" }, "scan_kind" => "other_kind" }] }
      )
    end

    it "ne claim que les jobs de la queue demandée" do
      result = use_case.call(queue: "scan:dns_records", worker_id: "w-4")
      expect(result.body[:empty]).to be true
    end
  end
end
