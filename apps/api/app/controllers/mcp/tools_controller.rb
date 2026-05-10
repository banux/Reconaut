# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "../../lib/mcp/tool_registry"
require_relative "../../lib/mcp/agent_chat_streamer"

# Controller HTTP qui expose les outils MCP. Le namespace de routes
# `/mcp/tools/:tool_name` accepte un POST JSON avec les paramètres ;
# la réponse est un JSON contenant le résultat de l'outil ou une
# erreur structurée. Le streaming SSE (cf. mcp-as-primary-entrypoint
# §1.2) est activé par content negotiation pour `agent_chat`.
#
# Cf. openspec/changes/init-reconaut-platform/specs/mcp-server/spec.md
#     openspec/changes/single-user-only/specs/mcp-server/spec.md
# (Requirement: MCP Authorization and Scopes — matrice purgée des rôles).
#
# Politique d'accès : en mode mono-user, c'est le set de scopes attaché
# à la clé API authentifiée (`Authorization: Bearer <api_key>`) qui
# détermine ce que l'appelant peut faire. Aucune notion de rôle.
module Mcp
  class ToolsController < ApplicationController
    include McpTlsPosture
    include ActionController::Live
    include IdentityResolver

    # Set complet des scopes possibles dans la matrice mono-user. Une
    # clé "full-scope" (générée par défaut via `reconautctl login`)
    # reçoit ce set ; une clé scopée explicitement reçoit un sous-ensemble.
    OPERATOR_SCOPES = Reconaut::Auth::Storage::InMemoryApiKeys::DEFAULT_SCOPES

    def invoke
      tool = Mcp::ToolRegistry.fetch(params[:tool_name])
      audit("invoke", tool.name)

      result = tool.call(
        params:        invocation_params,
        caller_id:     caller_id,
        caller_scopes: effective_scopes
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
    rescue Reconaut::Embedder::UnavailableError,
           Reconaut::Embedder::TimeoutError,
           Reconaut::Embedder::CircuitOpenError => e
      # Cf. openspec/changes/add-embedder-pluggable/specs/agent-interface/spec.md
      #   -> Requirement: Embedder Resilience (mapping 503).
      audit("invoke", params[:tool_name])
      provider_name = embedder_provider_for(params[:tool_name])
      reason = case e
               when Reconaut::Embedder::TimeoutError    then "timeout"
               when Reconaut::Embedder::CircuitOpenError then "circuit-open"
               else "backend-unavailable"
               end
      render status: :service_unavailable, json: {
        error:    "embedding_provider_unavailable",
        provider: provider_name,
        reason:   reason,
        message:  e.message
      }
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

    # Scopes effectifs de l'appelant : ceux portés par la clé API
    # courante. Si aucune clé valide n'est présente (cas des tests qui
    # n'ont pas encore migré vers Bearer), on retombe sur le set
    # complet — c'est sûr car l'auth ne devient stricte qu'avec
    # `RECONAUT_REQUIRE_API_KEY=true` (à activer en prod).
    def effective_scopes
      scopes = caller_scopes
      return scopes unless scopes.empty?
      return [] if ENV["RECONAUT_REQUIRE_API_KEY"] == "true"

      OPERATOR_SCOPES
    end

    def streaming_requested?
      accept = request.headers["Accept"].to_s
      return true if accept.include?("text/event-stream")

      params[:stream].to_s == "1"
    end

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

    # Best-effort lookup du provider embedder pour la 503 mapping.
    # Si l'embedder n'est pas câblé dans le Registry, retourne "unknown".
    def embedder_provider_for(_tool_name)
      reg = ::Reconaut::Registry.default
      embedder = reg.respond_to?(:embedder) ? reg.embedder : nil
      embedder&.provider || "unknown"
    rescue StandardError
      "unknown"
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
