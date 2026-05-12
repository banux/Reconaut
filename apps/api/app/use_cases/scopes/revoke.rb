# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "storage"
require_relative "result"

module Scopes
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
