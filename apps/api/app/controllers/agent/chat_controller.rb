# frozen_string_literal: true

require_relative "../../use_cases/agent/handle_query"

module Agent
  # Controller fin : delegue toute la logique a Agent::UseCases::HandleQuery.
  #
  # Cf. apps/web/src/api/agent.js (consommateur)
  # et init-reconaut-platform/specs/agent-interface/spec.md.
  #
  # Le pipeline reel (HybridRetriever) est resolu au runtime via
  # Reconaut::Registry.default.hybrid_retriever. Quand il est nil
  # (couche graphe pas encore cablee a la DB), on renvoie 503 plutot
  # que de fabriquer une reponse.
  class ChatController < ApplicationController
    include RoleResolver

    def create
      retriever = Reconaut::Registry.default.hybrid_retriever
      if retriever.nil?
        return render(
          status: 503,
          json: { error: "agent_pipeline_unavailable" }
        )
      end

      use_case = Agent::UseCases::HandleQuery.new(
        retriever: retriever,
        audit_recorder: Reconaut::Registry.default.audit_recorder
      )
      result = use_case.call(
        query: params[:query],
        caller_role: caller_role,
        caller_id: caller_id
      )
      render status: result.http_status, json: result.body
    end
  end
end
