# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/mcp/core_tools"

# Cf. openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
#   -> Requirement: MCP Tool `claim_scan_job` / `submit_scan_result` / `fail_scan_job`

RSpec.describe "MCP scanner tools (workers)", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }
  let(:audit)    { Agent::AuditRecorder::InMemoryRecorder.new }

  let(:retriever) do
    Class.new {
      def call(_) = Agent::HybridRetriever::Response.new(
        rows: [], citations: [], warnings: [], retrieval_path: "graph", duration_ms: 1
      )
    }.new
  end

  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.connection.execute("SELECT 1")
      unless ActiveRecord::Base.connection.table_exists?(:scan_results)
        @skip = "Table scan_results absente"
      end
      @gj_present = ActiveRecord::Base.connection.table_exists?(:good_jobs)
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before do
    skip(@skip) if @skip
    Mcp::ToolRegistry.reset!
    registry.scope_storage  = storage
    registry.audit_recorder = audit
    Mcp::CoreTools.register_all!(
      retriever: retriever,
      scope_storage: storage,
      scan_enqueuer: registry.scan_enqueuer,
      ingestion_recorder: audit
    )
    ActiveRecord::Base.connection.execute("DELETE FROM scan_results")
    ActiveRecord::Base.connection.execute("DELETE FROM good_jobs") if @gj_present
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  describe "submit_scan_result (happy path)" do
    it "POST /mcp/tools/submit_scan_result → 200 + insère ligne scan_results" do
      post "/mcp/tools/submit_scan_result",
        params: {
          job_id: "j-req-1",
          idempotency_key: "k-req-1",
          scan_kind: "dns_records",
          target_kind: "domain",
          target_value: "example.fr",
          status: %({"records":[]}),
          observed_at: "2026-05-13T12:00:00Z"
        }.to_json,
        headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result]).to include(ok: true)

      rows = ActiveRecord::Base.connection.execute(
        "SELECT idempotency_key FROM scan_results WHERE idempotency_key='k-req-1'"
      ).to_a
      expect(rows.size).to eq(1)
    end

    it "double submit → idempotent, 1 seule ligne" do
      payload = {
        job_id: "j-req-2",
        idempotency_key: "k-req-2",
        scan_kind: "dns_records", target_kind: "domain", target_value: "a.fr",
        status: "ok", observed_at: "2026-05-13T12:00:00Z"
      }
      2.times do
        post "/mcp/tools/submit_scan_result",
          params: payload.to_json,
          headers: { "Content-Type" => "application/json" }
        expect(response).to have_http_status(:ok)
      end
      count = ActiveRecord::Base.connection.execute(
        "SELECT COUNT(*) AS c FROM scan_results WHERE idempotency_key='k-req-2'"
      ).to_a.first["c"]
      expect(count).to eq(1)
    end

    it "idempotency_key vide → 400 (validation tool params)" do
      post "/mcp/tools/submit_scan_result",
        params: {
          job_id: "j-req-3",
          idempotency_key: "",
          scan_kind: "x", target_kind: "y", target_value: "z",
          status: "ok", observed_at: "2026-05-13T12:00:00Z"
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      expect(response.status).to be >= 400
    end
  end

  describe "claim_scan_job sur file vide" do
    it "retourne empty:true" do
      post "/mcp/tools/claim_scan_job",
        params: { queue: "scan:dns_records", worker_id: "w-req-1" }.to_json,
        headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result]).to include(empty: true)
    end
  end

  describe "fail_scan_job sans job réel" do
    it "retourne ok:true idempotent" do
      post "/mcp/tools/fail_scan_job",
        params: { job_id: "00000000-0000-0000-0000-000000000099", error: "boom" }.to_json,
        headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result]).to include(ok: true)
    end
  end

  describe "registration du tool" do
    it "claim_scan_job est enregistré avec scope worker:claim" do
      tool = Mcp::ToolRegistry.fetch("claim_scan_job")
      expect(tool.scopes).to include(:"worker:claim")
    end

    it "submit_scan_result et fail_scan_job ont scope worker:submit" do
      expect(Mcp::ToolRegistry.fetch("submit_scan_result").scopes).to include(:"worker:submit")
      expect(Mcp::ToolRegistry.fetch("fail_scan_job").scopes).to include(:"worker:submit")
    end
  end
end
