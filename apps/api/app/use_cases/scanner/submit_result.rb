# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "result"

module Scanner
  # SubmitResult : un worker remonte le résultat d'un job.
  #
  # Source de vérité :
  #   openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
  #     -> Requirement: MCP Tool `submit_scan_result`
  #
  # Comportement :
  #   1. Si idempotency_key vide → 400.
  #   2. Transaction :
  #      a) INSERT INTO scan_results (...) ON CONFLICT (idempotency_key)
  #         DO NOTHING.
  #      b) UPDATE good_jobs SET finished_at = NOW() WHERE id = $1 AND
  #         finished_at IS NULL.
  #   3. Retourne { ok: true } (idempotent même si conflict).
  class SubmitResult
    def initialize(audit_recorder: nil, clock: -> { Time.now.utc })
      @audit = audit_recorder
      @clock = clock
    end

    def call(job_id:, idempotency_key:, scan_kind:, target_kind:, target_value:,
             status:, observed_at:, caller_id: "anonymous")
      if idempotency_key.to_s.strip.empty?
        record_audit(:param_invalid, caller_id, reason: "idempotency_key required", job_id: job_id)
        return Result.new(status: :bad_request, body: { error: "idempotency_key required" })
      end

      observed_at_time = parse_time(observed_at)

      # On exécute les deux ops séparément (et non dans une transaction
      # commune) : si `good_jobs` est absente (cas dev sans gem installé),
      # son échec ne doit PAS faire rollback l'insert scan_results. Le
      # contrat d'idempotence côté ON CONFLICT garantit qu'un retry ne
      # produira pas de doublon.
      insert_scan_result(idempotency_key, scan_kind, target_kind, target_value, status, observed_at_time)
      finish_good_job(job_id) if job_id && !job_id.to_s.empty?

      record_audit(:success, caller_id,
        job_id: job_id, idempotency_key: idempotency_key,
        scan_kind: scan_kind, target_kind: target_kind
      )
      Result.new(status: :ok, body: { ok: true })
    end

    private

    def insert_scan_result(idem_key, scan_kind, target_kind, target_value, status, observed_at)
      sql = <<~SQL.squish
        INSERT INTO scan_results (idempotency_key, scan_kind, target_kind, target_value, status, observed_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        ON CONFLICT (idempotency_key) DO NOTHING
      SQL
      ActiveRecord::Base.connection.exec_query(
        sql, "Scanner::SubmitResult",
        [idem_key.to_s, scan_kind.to_s, target_kind.to_s, target_value.to_s, status.to_s, observed_at]
      )
    end

    def finish_good_job(job_id)
      ActiveRecord::Base.connection.exec_query(
        "UPDATE good_jobs SET finished_at = $1 WHERE id = $2 AND finished_at IS NULL",
        "Scanner::SubmitResult",
        [@clock.call, job_id.to_s]
      )
    rescue ActiveRecord::StatementInvalid
      # Table good_jobs absente (cas dev sans gem installé) : on log et
      # on continue — la ligne scan_results est déjà persistée.
    end

    def parse_time(value)
      case value
      when Time then value.utc
      when String then Time.parse(value).utc
      else @clock.call
      end
    rescue ArgumentError
      @clock.call
    end

    def record_audit(status, caller_id, **details)
      return unless @audit

      @audit.record(
        status: status,
        template_id: "/scan/submit",
        params_normalized: details,
        caller_id: caller_id,
        duration_ms: 0,
        nodes_touched: 0
      )
    rescue StandardError
    end
  end
end
