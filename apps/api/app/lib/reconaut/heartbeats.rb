# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "time"

module Reconaut
  # Heartbeats : registre des derniers battements de coeur reçus de
  # chaque worker Go. Source de vérité du probe Doctor
  # `last_worker_heartbeat`.
  #
  # Cf. openspec/changes/add-tech-stack/tasks.md section 6 (acceptance
  # bin/doctor : « version Go du dernier worker connu, dernier
  # schema_version connu côté Go »).
  module Heartbeats
    Record = Struct.new(:worker_id, :worker_version, :schema_version, :inflight_jobs, :scan_kind, :seen_at,
                        keyword_init: true) do
      def to_h
        {
          worker_id:      worker_id,
          worker_version: worker_version,
          schema_version: schema_version,
          inflight_jobs:  inflight_jobs,
          scan_kind:      scan_kind,
          seen_at:        seen_at
        }
      end
    end

    # Store en mémoire : dernier heartbeat par worker_id. Pour la v1
    # mono-instance, in-memory suffit ; un futur change DB-backed le
    # persistera quand le scaling horizontal des workers sera atteint.
    class InMemoryStore
      def initialize(clock: Time.method(:now))
        @clock = clock
        @latest = {}
        @mutex = Mutex.new
      end

      # Enregistre une heartbeat issue d'un payload `HeartbeatV1` validé
      # en amont. `payload` est un Hash (peut avoir des clés string ou
      # symbol — on tolère les deux).
      def record!(payload)
        worker_id      = string_at(payload, "worker_id")
        worker_version = string_at(payload, "version")
        inflight       = int_at(payload, "inflight_jobs")
        emitted_at     = string_at(payload, "emitted_at")
        schema_version = int_at(payload, "schema_version")
        scan_kind      = string_at(payload, "scan_kind")

        record = Record.new(
          worker_id:      worker_id,
          worker_version: worker_version,
          schema_version: schema_version,
          inflight_jobs:  inflight,
          scan_kind:      scan_kind,
          seen_at:        emitted_at || @clock.call.utc.iso8601
        )
        @mutex.synchronize { @latest[worker_id] = record }
        record
      end

      def latest
        @mutex.synchronize { @latest.values.max_by { |r| r.seen_at.to_s } }
      end

      def list
        @mutex.synchronize { @latest.values.dup }
      end

      def clear!
        @mutex.synchronize { @latest.clear }
      end

      private

      def string_at(hash, key)
        hash[key] || hash[key.to_sym]
      end

      def int_at(hash, key)
        v = string_at(hash, key)
        v.nil? ? nil : Integer(v)
      end
    end
  end
end
