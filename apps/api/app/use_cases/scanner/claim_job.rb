# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "result"

module Scanner
  # ClaimJob : un worker distant réclame le prochain job de sa queue.
  #
  # Source de vérité :
  #   openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
  #     -> Requirement: MCP Tool `claim_scan_job`
  #
  # Le use case :
  #   1. Ouvre une transaction.
  #   2. SELECT FOR UPDATE SKIP LOCKED sur good_jobs filtré par queue et
  #      lease expiré (performed_at IS NULL OU performed_at < NOW() - lease).
  #   3. Si target hors scope → marque le job finished_at + error="out-of-scope"
  #      et retourne empty:true.
  #   4. Sinon set performed_at=NOW() et retourne le job.
  #
  # Le use case est pur : pas de dépendance Rails, scope_storage et clock
  # sont injectables.
  class ClaimJob
    DEFAULT_LEASE_SECONDS = 300
    MAX_LEASE_SECONDS = 1800

    def initialize(scope_storage:, audit_recorder: nil, clock: -> { Time.now.utc })
      @scope_storage = scope_storage
      @audit         = audit_recorder
      @clock         = clock
    end

    def call(queue:, worker_id:, lease_seconds: DEFAULT_LEASE_SECONDS, caller_id: "anonymous")
      lease_seconds = lease_seconds.to_i
      lease_seconds = DEFAULT_LEASE_SECONDS if lease_seconds <= 0
      lease_seconds = MAX_LEASE_SECONDS    if lease_seconds > MAX_LEASE_SECONDS

      # En env de dev sans gem GoodJob installé, la table good_jobs
      # peut être absente — on traite comme "file vide" pour ne pas
      # faire crasher le worker. Production : la table existe toujours.
      unless ActiveRecord::Base.connection.table_exists?(:good_jobs)
        record_audit(:success, caller_id, queue: queue, worker_id: worker_id, outcome: "empty", note: "good_jobs absent")
        return Result.new(status: :ok, body: { empty: true })
      end

      ActiveRecord::Base.transaction do
        row = claim_row(queue, lease_seconds)
        if row.nil?
          record_audit(:success, caller_id, queue: queue, worker_id: worker_id, outcome: "empty")
          return Result.new(status: :ok, body: { empty: true })
        end

        params = parse_params(row["serialized_params"])
        target_kind, target_value = extract_target(params)

        if target_kind && target_value && !target_in_scope?(target_kind, target_value)
          mark_out_of_scope(row["id"])
          record_audit(:success, caller_id, queue: queue, worker_id: worker_id, outcome: "out-of-scope", job_id: row["id"])
          return Result.new(status: :ok, body: { empty: true })
        end

        mark_performed(row["id"])
        lease_until = @clock.call + lease_seconds
        record_audit(:success, caller_id, queue: queue, worker_id: worker_id, outcome: "claimed", job_id: row["id"])

        Result.new(
          status: :ok,
          body: {
            empty:       false,
            job: {
              id:           row["id"],
              params:       params,
              lease_until:  lease_until.iso8601
            }
          }
        )
      end
    end

    private

    # SELECT FOR UPDATE SKIP LOCKED — la lock dure le temps de la
    # transaction. La logique de re-claim s'appuie sur le filtre
    # performed_at NULL OR performed_at < lease_cutoff.
    def claim_row(queue, lease_seconds)
      lease_cutoff = @clock.call - lease_seconds
      sql = <<~SQL.squish
        SELECT id::text AS id, serialized_params
        FROM good_jobs
        WHERE queue_name = $1
          AND finished_at IS NULL
          AND (performed_at IS NULL OR performed_at < $2)
        ORDER BY priority ASC NULLS LAST,
                 scheduled_at ASC NULLS FIRST,
                 created_at ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1
      SQL
      result = exec_with_binds(sql, [queue, lease_cutoff])
      result.first
    end

    def mark_performed(id)
      exec_with_binds(
        "UPDATE good_jobs SET performed_at = $1 WHERE id = $2",
        [@clock.call, id]
      )
    end

    def mark_out_of_scope(id)
      exec_with_binds(
        "UPDATE good_jobs SET performed_at = COALESCE(performed_at, $1), finished_at = $1, error = $2 WHERE id = $3",
        [@clock.call, "out-of-scope", id]
      )
    end

    def parse_params(serialized)
      raw = serialized.is_a?(String) ? JSON.parse(serialized) : (serialized || {})
      # ActiveJob wrap : { "arguments" => [payload], ... }. On extrait le
      # payload (premier argument) si la structure le permet ; sinon on
      # retourne le hash tel quel (cas hand-rolled / test fixtures).
      if raw.is_a?(Hash) && raw["arguments"].is_a?(Array) && !raw["arguments"].empty?
        first = raw["arguments"].first
        return first if first.is_a?(Hash)
      end
      raw
    rescue JSON::ParserError
      {}
    end

    def extract_target(params)
      target = params.is_a?(Hash) ? params["target"] : nil
      return [nil, nil] unless target.is_a?(Hash)
      [target["kind"]&.to_s, target["value"]&.to_s]
    end

    def target_in_scope?(kind, value)
      return true if @scope_storage.nil?

      scopes = @scope_storage.list
      return false if scopes.empty?

      scopes.any? { |s| s.kind.to_s == kind && s.value.to_s == value }
    end

    def exec_with_binds(sql, binds)
      ActiveRecord::Base.connection.exec_query(sql, "Scanner::ClaimJob", binds)
    end

    def record_audit(status, caller_id, **details)
      return unless @audit

      @audit.record(
        status: status,
        template_id: "/scan/claim",
        params_normalized: details,
        caller_id: caller_id,
        duration_ms: 0,
        nodes_touched: 0
      )
    rescue StandardError
      # L'audit ne doit JAMAIS faire échouer le use case.
    end
  end
end
