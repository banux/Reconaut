# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "timeout"
require_relative "../graph_templates/registry"

# Wrapper d'execution d'un template Cypher. Couvre :
#   - le timeout par template (defaut 1500 ms, configurable),
#   - la degradation gracieuse quand AGE est indisponible (extension
#     absente, role mal configure, timeout depasse),
#   - les compteurs Prometheus (graph_unavailable_total,
#     graph_template_timeout_total{template_id}, retrieval_path_total).
#
# Source de verite :
#   openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md
#     -> Requirement: Graceful Degradation When Graph Unavailable
#     -> Scenario "Timeout de template"
#   openspec/changes/add-graph-retrieval/tasks.md sections 4.4 / 4.5
#
# L'executeur est *agnostique du moteur* : on lui injecte un objet
# `cypher_runner` qui repond a `call(graph:, cypher:, params:)`. En tests,
# on lui passe un fake (qui simule succes / timeout / extension manquante).
# En prod, c'est un wrapper sur `ActiveRecord::Base.connection.execute`
# pointe sur le rôle reconaut_graph_reader.
module Agent
  class TemplateExecutor
    DEFAULT_TIMEOUT_MS = (ENV.fetch("RECONAUT_GRAPH_TEMPLATE_TIMEOUT_MS", "1500")).to_i

    # Resultat structure rendu au pipeline.
    Result = Struct.new(:status, :rows, :nodes_touched, :duration_ms, :warning, keyword_init: true) do
      def ok?
        status == :success
      end

      def fallback_required?
        %i[timeout unavailable].include?(status)
      end
    end

    # Erreur applicative explicite pour pertes diverses (mauvais role
    # Postgres, extension non chargee, panne reseau DB).
    class GraphUnavailableError < StandardError; end

    def initialize(cypher_runner:, registry: GraphTemplates::Registry,
                   metrics: NullMetrics.new, timeout_ms: DEFAULT_TIMEOUT_MS,
                   graph_name: "reconaut")
      @cypher_runner = cypher_runner
      @registry      = registry
      @metrics       = metrics
      @timeout_ms    = timeout_ms
      @graph_name    = graph_name
    end

    def call(template_id, raw_params)
      template, params = @registry.resolve(template_id, raw_params)

      started = monotonic_ms
      rows = with_timeout do
        @cypher_runner.call(graph: @graph_name, cypher: template.cypher, params: params)
      end
      duration_ms = monotonic_ms - started

      @metrics.increment(:retrieval_path_total, path: "graph")
      @metrics.observe(:retrieval_latency_seconds, duration_ms / 1000.0, path: "graph")

      Result.new(
        status: :success,
        rows: rows,
        nodes_touched: rows.is_a?(Array) ? rows.length : 0,
        duration_ms: duration_ms,
        warning: nil
      )
    rescue Timeout::Error
      @metrics.increment(:graph_template_timeout_total, template_id: template_id)
      Result.new(
        status: :timeout,
        rows: [],
        nodes_touched: 0,
        duration_ms: @timeout_ms,
        warning: "graph_template_timeout"
      )
    rescue GraphUnavailableError => e
      @metrics.increment(:graph_unavailable_total, reason: classify(e.message))
      Result.new(
        status: :unavailable,
        rows: [],
        nodes_touched: 0,
        duration_ms: monotonic_ms - (defined?(started) ? started : monotonic_ms),
        warning: "graph_unavailable"
      )
    end

    private

    def with_timeout
      Timeout.timeout(@timeout_ms / 1000.0) { yield }
    end

    def monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
    end

    # Catégorise un message d'erreur DB pour la dimension Prometheus.
    def classify(message)
      case message.to_s
      when /extension/i, /not loaded/i then "extension_missing"
      when /permission denied/i        then "permission_denied"
      when /does not exist/i           then "object_missing"
      else "unknown"
      end
    end

    # Implementation de fallback quand on ne fournit pas de client metriques.
    class NullMetrics
      def increment(*); end
      def observe(*); end
    end
  end
end
