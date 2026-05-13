# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "result"

module Scanner
  # FailJob : un worker remonte une erreur terminale sur un job.
  # Pas de retry automatique en v1 — différé à `add-scan-retry-policy`.
  #
  # Source de vérité :
  #   openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
  #     -> Requirement: MCP Tool `fail_scan_job`
  class FailJob
    MAX_ERROR_LENGTH = 1024

    def initialize(audit_recorder: nil, clock: -> { Time.now.utc })
      @audit = audit_recorder
      @clock = clock
    end

    def call(job_id:, error:, caller_id: "anonymous")
      error_msg = error.to_s[0, MAX_ERROR_LENGTH]

      ActiveRecord::Base.connection.exec_query(
        "UPDATE good_jobs SET finished_at = $1, error = $2 WHERE id = $3 AND finished_at IS NULL",
        "Scanner::FailJob",
        [@clock.call, error_msg, job_id.to_s]
      )

      record_audit(:success, caller_id, job_id: job_id, error: error_msg[0, 200])
      Result.new(status: :ok, body: { ok: true })
    rescue ActiveRecord::StatementInvalid
      # Table good_jobs absente : no-op idempotent.
      record_audit(:success, caller_id, job_id: job_id, error: error_msg[0, 200], note: "good_jobs absent")
      Result.new(status: :ok, body: { ok: true })
    end

    private

    def record_audit(status, caller_id, **details)
      return unless @audit

      @audit.record(
        status: status,
        template_id: "/scan/fail",
        params_normalized: details,
        caller_id: caller_id,
        duration_ms: 0,
        nodes_touched: 0
      )
    rescue StandardError
    end
  end
end
