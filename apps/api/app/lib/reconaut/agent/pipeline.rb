# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Reconaut::Agent::Pipeline : factory qui assemble un Agent::HybridRetriever
# fonctionnel branché sur le retriever vectoriel pgvector.
#
# Cf. openspec/changes/add-embedding-pipeline/specs/agent-interface/spec.md
#   -> Requirement: Pipeline Wired into Registry at Boot
#
# Mode v1 : vector-only. Le router force toujours `semantic_query=query`
# (pas de décomposition LLM, différé à add-agent-router-llm) ; le
# template_executor retourne empty (pas de chemin graphe, différé à
# add-graph-retrieval-cypher-runner).

require_relative "../../agent/vector_retriever"

module Reconaut
  module Agent
    module Pipeline
      module_function

      def build(registry: ::Reconaut::Registry.default)
        ::Agent::HybridRetriever.new(
          router:            VectorOnlyRouter.new,
          template_executor: NullTemplateExecutor.new,
          vector_retriever:  ::Agent::VectorRetriever.new(embedder: registry.embedder)
        )
      end

      # VectorOnlyRouter : router déterministe qui force toujours la
      # voie vectorielle. Pas de LLM, pas de décomposition. Le
      # `semantic_query` retourné est la query brute.
      class VectorOnlyRouter
        Decision = Struct.new(:semantic_query, keyword_init: true) do
          def graph_path? = false
          def templates  = []
        end

        def route(user_query)
          Decision.new(semantic_query: user_query.to_s)
        end
      end

      # NullTemplateExecutor : implémentation qui retourne toujours
      # `ok? && rows=[]`. Branché en v1 où le chemin graphe n'est pas
      # actif (différé à add-graph-retrieval-cypher-runner).
      class NullTemplateExecutor
        Result = Struct.new(:rows, :warning, keyword_init: true) do
          def ok? = true
        end

        def call(_template_id, _params)
          Result.new(rows: [], warning: nil)
        end
      end
    end
  end
end
