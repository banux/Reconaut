# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/use_cases/scanner/fail_job"
require_relative "../../../app/lib/agent/audit_recorder"

# Cf. openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
#   -> Requirement: MCP Tool `fail_scan_job`

RSpec.describe Scanner::FailJob do
  let(:audit) { Agent::AuditRecorder::InMemoryRecorder.new }

  subject(:use_case) { described_class.new(audit_recorder: audit) }

  it "retourne ok:true même si good_jobs absente (idempotent)" do
    result = use_case.call(job_id: "j-1", error: "dial timeout")
    expect(result.status).to eq(:ok)
    expect(result.body).to eq(ok: true)
    expect(audit.entries.last[:template_id]).to eq("/scan/fail")
  end

  it "tronque les erreurs > 1024 chars" do
    long_error = "x" * 2000
    use_case.call(job_id: "j-2", error: long_error)
    # On vérifie que l'audit a tronqué (200 chars).
    expect(audit.entries.last[:params_normalized][:error].length).to be <= 200
  end

  context "avec table good_jobs présente" do
    before(:all) do
      @gj_skip = !ActiveRecord::Base.connection.table_exists?(:good_jobs)
    end

    before do
      skip "Table good_jobs absente" if @gj_skip
      ActiveRecord::Base.connection.execute("DELETE FROM good_jobs")
      ActiveRecord::Base.connection.execute(<<~SQL)
        INSERT INTO good_jobs (id, queue_name, serialized_params, created_at, performed_at)
        VALUES ('11111111-1111-1111-1111-111111111111', 'scan:dns_records', '{}', NOW(), NOW())
      SQL
    end

    it "met finished_at + error sur le job" do
      use_case.call(job_id: "11111111-1111-1111-1111-111111111111", error: "boom")
      row = ActiveRecord::Base.connection.execute(
        "SELECT finished_at, error FROM good_jobs WHERE id='11111111-1111-1111-1111-111111111111'"
      ).to_a.first
      expect(row["finished_at"]).not_to be_nil
      expect(row["error"]).to eq("boom")
    end
  end
end
