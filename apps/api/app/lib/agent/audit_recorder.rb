# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "json"

# Enregistre une trace d'audit pour chaque execution de template
# (succes, timeout, indisponibilite, parametre invalide, hors catalogue).
#
# Source de verite :
#   openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md
#     -> Requirement: Graph Query Audit
#   openspec/changes/add-graph-retrieval/tasks.md sections 5.1 / 5.2
#
# L'interface publique est volontairement minimale : `record(entry)`.
# Deux implementations vivent ici :
#   - InMemoryRecorder : utile en tests et en dev local.
#   - ActiveRecordRecorder : ecrit sur la table audit_log (outil
#     opérationnel, cf. spec `platform` modifiée par `drop-gdpr-framing`) ;
#     sera cable quand le modele AuditLog sera cree.
#
# Le recorder accepte n'importe quel hash respectant le schema d'entree :
#   {
#     template_id:        String | nil,   # nil quand status=unknown_template
#     params_normalized:  Hash,           # pas de valeurs sensibles
#     caller_id:          String,         # key_id ou user_id
#     duration_ms:        Integer,
#     nodes_touched:      Integer,
#     status:             :success | :timeout | :unauthorized
#                       | :unknown_template | :param_invalid
#                       | :unavailable
#   }
module Agent
  module AuditRecorder
    VALID_STATUSES = %i[
      success
      timeout
      unauthorized
      unknown_template
      param_invalid
      unavailable
    ].freeze

    REQUIRED_KEYS = %i[
      template_id
      params_normalized
      caller_id
      duration_ms
      nodes_touched
      status
    ].freeze

    class InvalidEntryError < StandardError; end

    module_function

    def normalize!(entry)
      entry = entry.to_h.transform_keys(&:to_sym)
      missing = REQUIRED_KEYS - entry.keys
      raise InvalidEntryError, "missing keys: #{missing.join(",")}" unless missing.empty?

      unless VALID_STATUSES.include?(entry[:status])
        raise InvalidEntryError, "invalid status: #{entry[:status]}"
      end

      # Defense en profondeur : on ne laisse pas une valeur de parametre
      # contenant un mot-cle sensible (heuristique, pas une garantie).
      stringified = JSON.generate(entry[:params_normalized])
      if stringified.match?(/(password|secret|token|api[_-]?key)/i)
        raise InvalidEntryError, "params_normalized must not contain sensitive keys"
      end

      entry
    end

    # Recorder en memoire utilise par les tests + le dev local. Thread-safe
    # via Mutex pour ne pas perdre d'entree quand plusieurs threads
    # ecrivent en parallele.
    class InMemoryRecorder
      def initialize
        @entries = []
        @mutex   = Mutex.new
      end

      def record(entry)
        normalized = AuditRecorder.normalize!(entry)
        @mutex.synchronize { @entries << normalized.dup.freeze }
      end

      def entries
        @mutex.synchronize { @entries.dup }
      end

      def clear!
        @mutex.synchronize { @entries.clear }
      end

      def count
        @mutex.synchronize { @entries.size }
      end
    end

    # Recorder ActiveRecord (DB). Cable a la table `audit_log` qui sera
    # creee par le change init-reconaut-platform. On utilise du SQL brut
    # pour ne pas dependre d'un modele Rails non encore livre - le
    # contrat reste `record(entry)`.
    class ActiveRecordRecorder
      def initialize(connection: ActiveRecord::Base.connection, table: "audit_log")
        @connection = connection
        @table      = table
      end

      def record(entry)
        normalized = AuditRecorder.normalize!(entry)
        @connection.exec_insert(insert_sql, "AuditRecorder#record", insert_binds(normalized))
      end

      private

      def insert_sql
        <<~SQL
          INSERT INTO #{@table}
            (template_id, params_normalized, caller_id, duration_ms,
             nodes_touched, status, recorded_at)
          VALUES ($1, $2::jsonb, $3, $4, $5, $6, NOW())
        SQL
      end

      def insert_binds(entry)
        [
          entry[:template_id],
          JSON.generate(entry[:params_normalized]),
          entry[:caller_id],
          entry[:duration_ms],
          entry[:nodes_touched],
          entry[:status].to_s
        ]
      end
    end
  end
end
