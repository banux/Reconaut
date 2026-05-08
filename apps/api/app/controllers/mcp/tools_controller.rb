# frozen_string_literal: true

require_relative "../../lib/mcp/tool_registry"
require_relative "../../lib/mcp/agent_chat_streamer"

# Controller HTTP qui expose les outils MCP. Le namespace de routes
# `/mcp/tools/:tool_name` accepte un POST JSON avec les parametres ;
# la reponse est un JSON contenant le resultat de l'outil ou une erreur
# structuree.
#
# Cf. openspec/changes/init-reconaut-platform/specs/mcp-server/spec.md.
# Le streaming SSE (cf. add-tech-stack 4.1) sera ajoute a une iteration
# suivante ; pour l'instant, reponse JSON synchrone qui couvre deja le
# scenario "appel d'outil REST partage avec API REST".
module Mcp
  class ToolsController < ApplicationController
    include ActionController::Live
    include RoleResolver

    # En mode mono-user (cf. openspec/changes/single-user-only/), tout
    # opérateur authentifié reçoit le rôle :operator avec un set de
    # scopes complet (la défense-en-profondeur passe par la limitation
    # des scopes attachés à chaque clé API, pas par les rôles serveur).
    # Les anciens rôles restent listés transitoirement pour absorber
    # les controllers hérités encore non purgés.
    OPERATOR_SCOPES = [
      :"read:hosts", :"read:scopes", :"write:scopes",
      :"read:scans", :"write:scans",
      :"read:reports", :"agent:chat",
      :"read:api_keys", :"write:api_keys",
      :"read:health", :"manage:scopes",
      :"write:heartbeats"
    ].freeze

    SCOPES_BY_ROLE = {
      operator:   OPERATOR_SCOPES,
      viewer:     [:"read:hosts", :"read:scopes"],
      analyst:    [:"read:hosts", :"read:scopes"],
      mcp_client: [:"read:hosts", :"read:scopes", :"write:scans"],
      admin:      [:"read:hosts", :"read:scopes", :"write:scans", :"manage:scopes"],
      owner:      OPERATOR_SCOPES
    }.freeze

    def invoke
      tool = Mcp::ToolRegistry.fetch(params[:tool_name])
      audit("invoke", tool.name)

      result = tool.call(
        params:        invocation_params,
        caller_id:     caller_id,
        caller_scopes: SCOPES_BY_ROLE.fetch(caller_role, [])
      )

      if streaming_requested? && tool.name == "agent_chat"
        stream_agent_chat!(result)
      else
        render status: :ok, json: { tool: tool.name, result: result }
      end
    rescue Mcp::UnknownToolError => e
      audit("unknown_tool", params[:tool_name])
      render status: :not_found, json: { error: "unknown_tool", message: e.message }
    rescue Mcp::ScopeError => e
      audit("rbac_forbidden", params[:tool_name])
      render status: :forbidden, json: { error: "rbac_forbidden", message: e.message }
    rescue Mcp::MissingParamError => e
      audit("missing_param", params[:tool_name])
      render status: :bad_request, json: { error: "missing_param", message: e.message }
    rescue Mcp::ParamTypeError, Mcp::ParamOutOfRangeError => e
      audit("param_invalid", params[:tool_name])
      render status: :bad_request, json: { error: "param_invalid", message: e.message }
    end

    def list
      tools = Mcp::ToolRegistry.all.map do |t|
        {
          name: t.name,
          scopes: t.scopes,
          params: t.params_schema.transform_values { |spec| spec.slice(:type, :required, :values, :min, :max) }
        }
      end
      render json: { tools: tools }
    end

    private

    # Le client demande un stream SSE en envoyant `Accept: text/event-stream`
    # ou en passant `?stream=1` (utile pour les tests qui ne contrôlent pas
    # facilement les headers Accept).
    def streaming_requested?
      accept = request.headers["Accept"].to_s
      return true if accept.include?("text/event-stream")

      params[:stream].to_s == "1"
    end

    # Reconstruit une `Agent::HybridRetriever::Response` à partir du Hash
    # rendu par le tool agent_chat puis émet une suite de tool_result
    # partiels via SSE. Le format des chunks est défini par
    # Mcp::AgentChatStreamer (cf. §1.2 du change mcp-as-primary-entrypoint).
    def stream_agent_chat!(result_hash)
      response.headers["Content-Type"]      = "text/event-stream"
      response.headers["Cache-Control"]     = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      reconstructed = Agent::HybridRetriever::Response.new(
        rows:           result_hash[:rows],
        citations:      result_hash[:citations].map { |c| Agent::HybridRetriever::Citation.new(**c.slice(:host_id, :scanned_at, :source)) },
        warnings:       result_hash[:warnings],
        retrieval_path: result_hash[:retrieval_path],
        duration_ms:    result_hash[:duration_ms]
      )

      Mcp::AgentChatStreamer.chunks_for(reconstructed).each do |chunk|
        event = {
          tool:    "agent_chat",
          partial: chunk[:type] != "done",
          result:  chunk
        }
        response.stream.write("event: tool_result\n")
        response.stream.write("data: #{event.to_json}\n\n")
      end
    ensure
      response.stream.close
    end

    def invocation_params
      raw = params.to_unsafe_h.except("controller", "action", "tool_name", "format")
      raw
    end

    def audit(status_kind, tool_name)
      audit_recorder = Reconaut::Registry.default.audit_recorder
      return unless audit_recorder

      audit_status = case status_kind
                     when "invoke"          then :success
                     when "unknown_tool"    then :unknown_template
                     when "rbac_forbidden"  then :unauthorized
                     when "missing_param", "param_invalid" then :param_invalid
                     else :success
                     end

      audit_recorder.record(
        status: audit_status,
        template_id: "mcp:#{tool_name}",
        params_normalized: { kind: status_kind },
        caller_id: caller_id,
        duration_ms: 0,
        nodes_touched: 0
      )
    rescue StandardError
    end
  end
end
