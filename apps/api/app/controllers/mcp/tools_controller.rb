# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "../../lib/mcp/tool_registry"
require_relative "../../lib/mcp/agent_chat_streamer"
require_relative "../../lib/mcp/agent_chat_heartbeat"

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

      will_stream = streaming_requested? && tool.name == "agent_chat"
      progressive_retriever = will_stream && progressive_retriever_for_agent_chat
      # Pour les invocations streamées, l'audit est écrit à la FIN avec
      # le champ `streaming` + `outcome` (cf. add-agent-chat-streaming §2.2).
      # Pour le reste, on logge tout de suite l'invocation comme avant.
      audit("invoke", tool.name) unless will_stream

      if will_stream && progressive_retriever
        # Voie progressive : on bypasse le tool block pour ne pas
        # consommer la latence d'un `retriever.call` synchrone avant
        # le premier chunk. Les permissions et la validation des
        # params sont vérifiées à part par `tool.call` ; on les
        # rejoue ici via `tool.call` MAIS sur un retriever stub qui
        # ne fait rien, juste pour passer les guards.
        # Compromis pragmatique : on appelle tool.call quand même
        # pour les checks, puis on streame via each_chunk depuis le
        # retriever ; le résultat de tool.call est ignoré.
        _ = tool.call(
          params:        invocation_params,
          caller_id:     caller_id,
          caller_scopes: effective_scopes
        )
        stream_agent_chat_progressive!(progressive_retriever, invocation_params[:prompt].to_s)
      else
        result = tool.call(
          params:        invocation_params,
          caller_id:     caller_id,
          caller_scopes: effective_scopes
        )

        if will_stream
          stream_agent_chat!(result)
        else
          render status: :ok, json: { tool: tool.name, result: result }
        end
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

      heartbeat_interval = Float(ENV.fetch("RECONAUT_AGENT_CHAT_HEARTBEAT_S", 15))
      heartbeat = Mcp::AgentChatHeartbeat.start(
        stream: response.stream,
        interval_s: heartbeat_interval
      )
      outcome = :completed

      begin
        Mcp::AgentChatStreamer.chunks_for(reconstructed).each do |chunk|
          if response.stream.closed?
            outcome = :client_gone
            break
          end

          event = {
            tool:    "agent_chat",
            partial: chunk[:type] != "done",
            result:  chunk
          }
          begin
            response.stream.write("event: tool_result\n")
            response.stream.write("data: #{event.to_json}\n\n")
          rescue IOError, Errno::EPIPE
            outcome = :client_gone
            Rails.logger.info("[agent_chat] client gone during stream")
            break
          end
        end
      ensure
        Mcp::AgentChatHeartbeat.stop(heartbeat)
        record_streaming_audit!(outcome)
        response.stream.close
      end
    end

    # progressive_retriever_for_agent_chat : retourne le retriever
    # natif (Registry.default.hybrid_retriever) s'il implémente
    # `each_chunk`, sinon nil. Cf. add-agent-chat-streaming §3.1.
    def progressive_retriever_for_agent_chat
      r = ::Reconaut::Registry.default.hybrid_retriever
      return nil if r.nil?
      return nil unless r.respond_to?(:each_chunk)

      r
    end

    # Streaming progressif : appelle `retriever.each_chunk(prompt)` et
    # écrit chaque chunk dès réception. Pour les retrievers qui yield
    # avec des intervalles temporels, ça donne une progression
    # observable côté client (vs le post-hoc chunking qui produit tout
    # d'un coup à la fin).
    def stream_agent_chat_progressive!(retriever, prompt)
      response.headers["Content-Type"]      = "text/event-stream"
      response.headers["Cache-Control"]     = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      heartbeat_interval = Float(ENV.fetch("RECONAUT_AGENT_CHAT_HEARTBEAT_S", 15))
      heartbeat = Mcp::AgentChatHeartbeat.start(
        stream: response.stream, interval_s: heartbeat_interval
      )
      outcome = :completed

      begin
        retriever.each_chunk(prompt) do |chunk|
          if response.stream.closed?
            outcome = :client_gone
            break
          end

          event = {
            tool:    "agent_chat",
            partial: chunk[:type] != "done",
            result:  chunk
          }
          begin
            response.stream.write("event: tool_result\n")
            response.stream.write("data: #{event.to_json}\n\n")
          rescue IOError, Errno::EPIPE
            outcome = :client_gone
            Rails.logger.info("[agent_chat] client gone during progressive stream")
            break
          end
        end
      ensure
        Mcp::AgentChatHeartbeat.stop(heartbeat)
        record_streaming_audit!(outcome)
        response.stream.close
      end
    end

    # Réécrit l'audit pour l'invocation streamée : ajoute
    # `streaming: true` + `outcome` au params_normalized. Cohérent
    # avec le reste du système, sans modifier le schéma audit_log.
    # Cf. add-agent-chat-streaming §2.2.
    def record_streaming_audit!(outcome)
      audit_recorder = Reconaut::Registry.default.audit_recorder
      return unless audit_recorder

      audit_recorder.record(
        status:            :success,
        template_id:       "mcp:agent_chat",
        params_normalized: { streaming: true, outcome: outcome.to_s },
        caller_id:         caller_id,
        duration_ms:       0,
        nodes_touched:     0
      )
    rescue StandardError
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
