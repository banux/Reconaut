# frozen_string_literal: true

require_relative "../use_cases/scopes/operations"

# Controller fin : delegue toute la logique aux use cases Scopes::UseCases.
#
# Cf. apps/web/src/api/scopes.js (consommateur)
# et init-reconaut-platform/tasks.md section 2.4.
class ScopesController < ApplicationController
  include RoleResolver

  def index
    use_case = Scopes::UseCases::List.new(storage: storage)
    result   = use_case.call(caller_role: caller_role)
    render status: result.http_status, json: result.body
  end

  def create
    use_case = Scopes::UseCases::Add.new(storage: storage, audit_recorder: audit)
    result = use_case.call(
      kind: params[:kind],
      value: params[:value],
      caller_role: caller_role,
      caller_id: caller_id
    )
    render status: result.http_status, json: result.body
  end

  def destroy
    use_case = Scopes::UseCases::Revoke.new(storage: storage, audit_recorder: audit)
    result = use_case.call(
      id: params[:id],
      caller_role: caller_role,
      caller_id: caller_id
    )

    if result.body.nil?
      head result.http_status
    else
      render status: result.http_status, json: result.body
    end
  end

  private

  def storage
    Reconaut::Registry.default.scope_storage
  end

  def audit
    Reconaut::Registry.default.audit_recorder
  end
end
