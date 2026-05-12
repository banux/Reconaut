# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "storage"
require_relative "result"

module Scopes
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
end
