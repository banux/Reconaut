# frozen_string_literal: true

require_relative "../../lib/agent/hybrid_retriever"

module Agent
  module UseCases
    # Use case appele par le controller POST /agent/chat. Application :
    #   - applique le RBAC : viewer -> 403, analyst+ -> autorise.
    #   - delegue le retrieval a Agent::HybridRetriever.
    #   - normalise le shape de la reponse pour le frontend (cf.
    #     apps/web/src/api/agent.js).
    #   - enregistre une ligne d'audit pour chaque appel (success ou
    #     unauthorized) via Agent::AuditRecorder.
    #
    # Source de verite :
    #   openspec/changes/init-reconaut-platform/specs/agent-interface/spec.md
    #   openspec/changes/add-graph-retrieval/specs/agent-interface/spec.md
    #     -> Requirement: RBAC-Scoped Conversation Context
    #
    # Use case pur : aucun couplage Rails, aucune DB ; tout est injectable.
    class HandleQuery
      AUTHORIZED_ROLES = %i[analyst admin owner].freeze

      Result = Struct.new(:status, :body, keyword_init: true) do
        def http_status
          { ok: 200, unauthorized: 403, bad_request: 400 }.fetch(status, 500)
        end
      end

      def initialize(retriever:, audit_recorder: nil)
        @retriever = retriever
        @audit     = audit_recorder
      end

      def call(query:, caller_role:, caller_id: "anonymous")
        if query.to_s.strip.empty?
          return error(:bad_request, "query_required", caller_id: caller_id)
        end

        unless AUTHORIZED_ROLES.include?(caller_role)
          record_audit(:unauthorized, caller_id: caller_id, template_id: nil,
                       params_normalized: { reason: "rbac_forbidden" },
                       duration_ms: 0, nodes_touched: 0)
          return Result.new(status: :unauthorized, body: { error: "rbac_forbidden" })
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
        # L'audit ne doit JAMAIS faire echouer la requete utilisateur.
      end
    end
  end
end
