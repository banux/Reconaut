# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/use_cases/scanner/submit_result"
require_relative "../../../app/lib/agent/audit_recorder"

# Cf. openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
#   -> Requirement: MCP Tool `submit_scan_result`

RSpec.describe Scanner::SubmitResult do
  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.connection.execute("SELECT 1")
      unless ActiveRecord::Base.connection.table_exists?(:scan_results)
        @skip = "Table scan_results absente — lance `RAILS_ENV=test bundle exec rails db:migrate`"
      end
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before(:each) do
    skip(@skip) if @skip
    ActiveRecord::Base.connection.execute("DELETE FROM scan_results")
  end

  let(:audit) { Agent::AuditRecorder::InMemoryRecorder.new }
  subject(:use_case) { described_class.new(audit_recorder: audit) }

  it "insère la ligne scan_results + audit success" do
    result = use_case.call(
      job_id: "00000000-0000-0000-0000-000000000001",
      idempotency_key: "k-1",
      scan_kind: "dns_records",
      target_kind: "domain",
      target_value: "example.fr",
      status: %({"records":[]}),
      observed_at: "2026-05-13T12:00:00Z",
      caller_id: "key:worker-1"
    )
    expect(result.status).to eq(:ok)
    expect(result.body).to eq(ok: true)

    rows = ActiveRecord::Base.connection.execute("SELECT * FROM scan_results WHERE idempotency_key='k-1'").to_a
    expect(rows.size).to eq(1)
    expect(rows.first["status"]).to eq(%({"records":[]}))

    expect(audit.entries.last[:status]).to eq(:success)
    expect(audit.entries.last[:template_id]).to eq("/scan/submit")
  end

  it "double submit (même idempotency_key) → idempotent, 1 ligne" do
    args = {
      job_id: "00000000-0000-0000-0000-000000000002",
      idempotency_key: "k-dup",
      scan_kind: "dns_records",
      target_kind: "domain",
      target_value: "a.fr",
      status: "ok",
      observed_at: "2026-05-13T12:00:00Z"
    }
    use_case.call(**args)
    result = use_case.call(**args)
    expect(result.status).to eq(:ok)

    count = ActiveRecord::Base.connection.execute(
      "SELECT COUNT(*) AS c FROM scan_results WHERE idempotency_key='k-dup'"
    ).to_a.first["c"]
    expect(count).to eq(1)
  end

  it "idempotency_key vide → 400 sans insertion" do
    result = use_case.call(
      job_id: "j", idempotency_key: "",
      scan_kind: "x", target_kind: "y", target_value: "z",
      status: "ok", observed_at: Time.now.utc
    )
    expect(result.status).to eq(:bad_request)
    expect(result.body[:error]).to eq("idempotency_key required")

    expect(audit.entries.last[:status]).to eq(:param_invalid)
  end

  it "idempotency_key whitespace-only → 400" do
    result = use_case.call(
      job_id: "j", idempotency_key: "   ",
      scan_kind: "x", target_kind: "y", target_value: "z",
      status: "ok", observed_at: Time.now.utc
    )
    expect(result.status).to eq(:bad_request)
  end
end
