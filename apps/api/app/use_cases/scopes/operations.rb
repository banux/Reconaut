# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "storage"

module Scopes
  module UseCases
    Result = Struct.new(:status, :body, keyword_init: true) do
      HTTP_MAP = {
        ok:           200,
        created:      201,
        no_content:   204,
        bad_request:  400,
        not_found:    404
      }.freeze

      def http_status
        HTTP_MAP.fetch(status, 500)
      end
    end

    # En mode mono-user (cf. openspec/changes/single-user-only/), il n'y
    # a plus de notion de rôle. Le contrôle d'accès vit (a) au niveau
    # MCP scope (Mcp::Tool#call vérifie `caller_scopes`), et (b) à
    # l'authentification (la présence d'une clé API valide). Les use
    # cases ne ré-implémentent plus la matrice — ils prennent juste
    # `caller_id:` pour l'audit.

    class List
      def initialize(storage:)
        @storage = storage
      end

      def call(caller_id: "anonymous")
        _ = caller_id # réservé à l'audit éventuel ; la lecture n'est pas auditée
        Result.new(
          status: :ok,
          body: { scopes: @storage.list.map(&:to_h) }
        )
      end
    end

    class Add
      def initialize(storage:, audit_recorder: nil)
        @storage = storage
        @audit   = audit_recorder
      end

      def call(kind:, value:, caller_id: "anonymous")
        begin
          scope = @storage.create(kind: kind, value: value)
        rescue ArgumentError => e
          record_audit(:param_invalid, caller_id, kind: kind, value: value, code: e.message)
          return Result.new(
            status: :bad_request,
            body: { error: e.message }
          )
        end

        record_audit(:success, caller_id, kind: kind, value: value, scope_id: scope.id)
        Result.new(status: :created, body: { scope: scope.to_h })
      end

      private

      def record_audit(status, caller_id, **details)
        return unless @audit

        @audit.record(
          status: status,
          template_id: "/scopes",
          params_normalized: { action: "create" }.merge(details),
          caller_id: caller_id,
          duration_ms: 0,
          nodes_touched: 0
        )
      rescue StandardError
        # ne fait jamais échouer le use case
      end
    end

    class Revoke
      def initialize(storage:, audit_recorder: nil)
        @storage = storage
        @audit   = audit_recorder
      end

      def call(id:, caller_id: "anonymous")
        scope = @storage.delete(id)
        if scope.nil?
          record_audit(:param_invalid, caller_id, scope_id: id, code: "not_found")
          return Result.new(status: :not_found, body: { error: "scope_not_found" })
        end

        record_audit(:success, caller_id, scope_id: id, kind: scope.kind, value: scope.value)
        Result.new(status: :no_content, body: nil)
      end

      private

      def record_audit(status, caller_id, **details)
        return unless @audit

        @audit.record(
          status: status,
          template_id: "/scopes",
          params_normalized: { action: "revoke" }.merge(details),
          caller_id: caller_id,
          duration_ms: 0,
          nodes_touched: 0
        )
      rescue StandardError
      end
    end
  end
end
