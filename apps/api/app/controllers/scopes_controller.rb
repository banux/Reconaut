# frozen_string_literal: true

require_relative "../use_cases/scopes/operations"

# DEPRECATED : controller REST historique, sera retiré dans le futur
# change `remove-rest-wrappers` une fois la TUI migrée sur MCP.
# Toute nouvelle feature de gestion de scope DOIT s'exposer comme outil
# MCP (cf. add_scope / revoke_scope / list_scopes dans
# Mcp::CoreTools), pas étendre ce controller.
#
# Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
# (Requirement: REST API Reduced to Bootstrap, Health and MCP Transport).
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
