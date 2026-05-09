# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "time"

module Reconaut
  # Scans : registre des scans demandés. Garde une trace minimaliste
  # (id, kind, target, status, timestamps) pour alimenter les tools MCP
  # `list_scans` et `get_scan_status`.
  #
  # Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
  # (Requirement: MCP Tool Surface, scopes read:scans / write:scans).
  #
  # Statuts : queued (juste enqueué), running (worker l'a pris), done
  # (terminé), failed (erreur worker). En v1 mono-instance, le worker
  # Go appellera un futur tool MCP `update_scan_status` ; en attendant,
  # tout scan reste à `queued` après enqueue.
  module Scans
    STATUSES = %w[queued running done failed].freeze

    Record = Struct.new(
      :scan_id, :scan_kind, :target_kind, :target_value,
      :idempotency_key, :status, :enqueued_at, :started_at, :completed_at,
      keyword_init: true
    ) do
      def to_h
        {
          scan_id:         scan_id,
          scan_kind:       scan_kind,
          target_kind:     target_kind,
          target_value:    target_value,
          idempotency_key: idempotency_key,
          status:          status,
          enqueued_at:     enqueued_at,
          started_at:      started_at,
          completed_at:    completed_at
        }
      end
    end

    # Store in-memory. Mono-process suffit en v1 ; un store DB-backed
    # remplacera ce module quand on aura besoin de persister entre
    # redémarrages ou de scaler horizontalement.
    class InMemoryStore
      def initialize(clock: Time.method(:now))
        @clock  = clock
        @by_id  = {}
        @order  = []
        @mutex  = Mutex.new
      end

      def record!(scan_id:, scan_kind:, target_kind:, target_value:,
                  idempotency_key:, enqueued_at: nil)
        record = Record.new(
          scan_id:         scan_id,
          scan_kind:       scan_kind.to_s,
          target_kind:     target_kind.to_s,
          target_value:    target_value.to_s,
          idempotency_key: idempotency_key,
          status:          "queued",
          enqueued_at:     (enqueued_at || @clock.call.utc).iso8601,
          started_at:      nil,
          completed_at:    nil
        )
        @mutex.synchronize do
          @by_id[scan_id] = record
          @order << scan_id unless @order.include?(scan_id)
        end
        record
      end

      def find(scan_id)
        @mutex.synchronize { @by_id[scan_id] }
      end

      def list(limit: 50)
        @mutex.synchronize do
          ids = @order.last(limit).reverse
          ids.map { |id| @by_id[id] }.compact
        end
      end

      def clear!
        @mutex.synchronize do
          @by_id.clear
          @order.clear
        end
      end
    end
  end
end
