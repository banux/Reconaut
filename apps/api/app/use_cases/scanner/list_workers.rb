# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "result"

module Scanner
  # ListWorkers : retourne les workers ayant émis un heartbeat
  # récemment. Source de vérité du tool MCP `list_workers`.
  #
  # Cf. openspec/changes/add-worker-observability/specs/mcp-server/spec.md
  #   -> Requirement: MCP Tool `list_workers`
  #
  # Pas de couplage Rails : on injecte un `heartbeat_store` qui répond
  # à `#list -> [Record]`.
  class ListWorkers
    DEFAULT_RECENT_SECONDS = 300
    MAX_RECENT_SECONDS     = 3600

    def initialize(heartbeat_store:, clock: -> { Time.now.utc })
      @store = heartbeat_store
      @clock = clock
    end

    def call(recent_seconds: DEFAULT_RECENT_SECONDS, caller_id: "anonymous")
      _ = caller_id # réservé à l'audit éventuel (lecture non auditée en v1)

      window = clamp_window(recent_seconds)
      cutoff = @clock.call - window
      now    = @clock.call

      records = @store.list || []
      active = records.filter_map do |r|
        seen_time = parse_time(r.seen_at)
        next nil if seen_time.nil? || seen_time < cutoff

        {
          worker_id:                r.worker_id,
          scan_kind:                r.scan_kind,
          version:                  r.worker_version,
          inflight_jobs:            r.inflight_jobs,
          seen_at:                  r.seen_at,
          seconds_since_last_seen:  (now - seen_time).to_i
        }
      end

      active.sort_by! { |w| w[:seconds_since_last_seen] }

      Result.new(status: :ok, body: { workers: active })
    end

    private

    def clamp_window(n)
      n = n.to_i
      n = DEFAULT_RECENT_SECONDS if n <= 0
      n = MAX_RECENT_SECONDS    if n > MAX_RECENT_SECONDS
      n
    end

    def parse_time(s)
      return nil if s.nil? || s.to_s.empty?
      Time.parse(s.to_s)
    rescue ArgumentError
      nil
    end
  end
end
