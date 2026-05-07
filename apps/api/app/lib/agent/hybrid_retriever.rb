# frozen_string_literal: true

require_relative "query_router"
require_relative "template_executor"

# Pipeline de retrieval hybride : compose le routeur (decomposition LLM),
# l'executor de templates (chemin graphe) et un retriever vectoriel
# (chemin semantique). Renvoie une reponse structuree avec citations,
# warnings et le chemin emprunte.
#
# Source de verite :
#   openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md
#     -> Requirement: Hybrid Retrieval Pipeline
#     -> Requirement: Graceful Degradation When Graph Unavailable
#   openspec/changes/add-graph-retrieval/specs/agent-interface/spec.md
#     -> Requirement: Semantic Search over Indexed Assets
#   openspec/changes/add-graph-retrieval/tasks.md sections 4.2 / 4.3
module Agent
  class HybridRetriever
    Response = Struct.new(:rows, :citations, :warnings, :retrieval_path,
                          :duration_ms, keyword_init: true)

    Citation = Struct.new(:host_id, :scanned_at, :source, keyword_init: true)

    PATH_VECTOR = "vector"
    PATH_GRAPH  = "graph"
    PATH_HYBRID = "hybrid"
    PATH_NONE   = "none"

    def initialize(router:, template_executor:, vector_retriever:,
                   metrics: TemplateExecutor::NullMetrics.new)
      @router            = router
      @template_executor = template_executor
      @vector_retriever  = vector_retriever
      @metrics           = metrics
    end

    def call(user_query)
      started = monotonic_ms
      warnings = []
      graph_rows = []
      vector_rows = []

      decision = safely_decide(user_query, warnings)

      # --- Chemin graphe (si templates choisis) -----------------------------
      if decision&.graph_path?
        decision.templates.each do |plan|
          result = @template_executor.call(plan.template_id, plan.params)
          warnings << result.warning if result.warning
          graph_rows.concat(Array(result.rows)) if result.ok?
        end
      end

      # --- Chemin vectoriel ------------------------------------------------
      semantic_query = decision&.semantic_query.to_s
      semantic_query = user_query if semantic_query.strip.empty?

      vector_rows = safely_recall(semantic_query, warnings)

      # --- Composition + metriques -----------------------------------------
      path = classify_path(graph_rows.any?, vector_rows.any?)
      duration_ms = monotonic_ms - started

      @metrics.increment(:retrieval_path_total, path: path)
      @metrics.observe(:retrieval_latency_seconds, duration_ms / 1000.0, path: path)

      Response.new(
        rows: dedupe_by_host(graph_rows + vector_rows),
        citations: build_citations(graph_rows + vector_rows),
        warnings: warnings.uniq,
        retrieval_path: path,
        duration_ms: duration_ms
      )
    end

    private

    def safely_decide(user_query, warnings)
      @router.route(user_query)
    rescue QueryRouter::InvalidLLMResponseError
      warnings << "router_invalid_response"
      nil
    rescue GraphTemplates::Error
      # template inconnu / param invalide cote LLM : on retombe en
      # vector pur plutot que de propager une erreur a l'utilisateur.
      warnings << "router_rejected_plan"
      nil
    end

    def safely_recall(semantic_query, warnings)
      Array(@vector_retriever.call(semantic_query))
    rescue StandardError
      warnings << "vector_unavailable"
      []
    end

    def classify_path(graph_present, vector_present)
      return PATH_HYBRID if graph_present && vector_present
      return PATH_GRAPH  if graph_present
      return PATH_VECTOR if vector_present

      PATH_NONE
    end

    # Deduplique sur host_id : le meme hote peut etre rapporte par les
    # deux chemins.
    def dedupe_by_host(rows)
      seen = {}
      rows.each do |row|
        key = (row.is_a?(Hash) ? (row["host_id"] || row[:host_id]) : nil)
        next if key.nil? || seen.key?(key)

        seen[key] = row
      end
      seen.values
    end

    # Citations (host_id, scanned_at) - exigence "chaque resultat DOIT citer
    # son enregistrement de scan source" de agent-interface.
    def build_citations(rows)
      rows.filter_map do |row|
        next unless row.is_a?(Hash)

        host_id    = row["host_id"]    || row[:host_id]
        scanned_at = row["scanned_at"] || row[:scanned_at]
        next unless host_id

        Citation.new(host_id: host_id, scanned_at: scanned_at, source: row[:source] || "unknown")
      end
    end

    def monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
    end
  end
end
