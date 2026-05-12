# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "../../lib/agent/hybrid_retriever"

module Agent
  # Use case `agent_chat` (invoqué par le tool MCP du même nom).
  # Application :
  #   - délègue le retrieval à Agent::HybridRetriever ;
  #   - normalise la forme de la réponse (rows + citations + metadata) ;
  #   - enregistre une ligne d'audit pour chaque appel via
  #     Agent::AuditRecorder.
  #
  # Source de vérité :
  #   openspec/changes/init-reconaut-platform/specs/agent-interface/spec.md
  #   openspec/changes/add-graph-retrieval/specs/agent-interface/spec.md
  #   openspec/changes/single-user-only/specs/platform/spec.md
  #     -> Plus de notion de rôle ; le contrôle d'accès est porté par
  #        les scopes MCP (`agent:chat`).
  #
  # NB : la classe vit sous `Agent::HandleQuery` (et plus
  # `Agent::UseCases::HandleQuery`). Le module `UseCases` a été drop
  # pour aligner sur Zeitwerk en eager_load CI — le fichier
  # `app/use_cases/agent/handle_query.rb` doit définir la constante
  # `Agent::HandleQuery` puisque `app/use_cases/` est un autoload
  # root Rails (le nom du dir ne contribue pas au namespace).
  #
  # Use case pur : aucun couplage Rails, aucune DB ; tout est injectable.
  class HandleQuery
    Result = Struct.new(:status, :body, keyword_init: true) do
      def http_status
        { ok: 200, bad_request: 400 }.fetch(status, 500)
      end
    end

    def initialize(retriever:, audit_recorder: nil)
      @retriever = retriever
      @audit     = audit_recorder
    end

    def call(query:, caller_id: "anonymous")
      if query.to_s.strip.empty?
        return error(:bad_request, "query_required", caller_id: caller_id)
      end

      response = @retriever.call(query)

      record_audit(:success, caller_id: caller_id, template_id: "/agent/chat",
                   params_normalized: { retrieval_path: response.retrieval_path },
                   duration_ms: response.duration_ms, nodes_touched: response.rows.size)

      Result.new(
        status: :ok,
        body: {
          rows:           response.rows,
          citations:      response.citations.map(&:to_h),
          warnings:       response.warnings,
          retrieval_path: response.retrieval_path,
          duration_ms:    response.duration_ms
        }
      )
    end

    private

    def error(status, code, caller_id:)
      record_audit(:param_invalid, caller_id: caller_id, template_id: nil,
                   params_normalized: { reason: code },
                   duration_ms: 0, nodes_touched: 0)
      Result.new(status: status, body: { error: code })
    end

    def record_audit(status, **fields)
      return unless @audit

      @audit.record(
        status: status,
        template_id: fields[:template_id],
        params_normalized: fields[:params_normalized] || {},
        caller_id: fields[:caller_id],
        duration_ms: fields[:duration_ms].to_i,
        nodes_touched: fields[:nodes_touched].to_i
      )
    rescue StandardError
      # L'audit ne doit JAMAIS faire échouer la requête utilisateur.
    end
  end
end
