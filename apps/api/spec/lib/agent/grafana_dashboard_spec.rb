# frozen_string_literal: true

require "spec_helper"
require "json"

# Vérifie que le dashboard Grafana versionné dans
# ops/grafana/graph-retrieval.json référence uniquement des métriques
# que le code applicatif émet effectivement.
#
# Cf. openspec/changes/add-graph-retrieval/tasks.md §7.2.
#
# La règle : si le dashboard interroge `foo_total`, alors le code
# DOIT contenir au moins un appel `metrics.increment(:foo_total, ...)`
# ou `metrics.observe(:foo, ...)`. Sinon, le panel renverrait
# silencieusement vide en production — un piège opérationnel.
RSpec.describe "Grafana graph-retrieval dashboard" do
  REPO_ROOT = File.expand_path("../../../../..", __dir__).freeze
  DASHBOARD_PATH = File.join(REPO_ROOT, "ops/grafana/graph-retrieval.json").freeze
  CODE_GLOB = File.join(REPO_ROOT, "apps/api/app/lib/**/*.rb").freeze

  # Liste des métriques qu'on s'attend à trouver dans le code.
  # Le panel `graph_lag_seconds` est livré avec §2.3 (projection AGE) ;
  # il sera réintroduit dans le dashboard quand la métrique sera émise
  # par la couche de projection.
  EXPECTED_METRICS = %w[
    retrieval_path_total
    retrieval_latency_seconds
    graph_unavailable_total
    graph_template_timeout_total
  ].freeze

  let(:dashboard) { JSON.parse(File.read(DASHBOARD_PATH)) }
  let(:code_corpus) { Dir[CODE_GLOB].map { |f| File.read(f) }.join("\n") }

  it "le fichier JSON est syntaxiquement valide" do
    expect { JSON.parse(File.read(DASHBOARD_PATH)) }.not_to raise_error
  end

  it "uid et title canoniques" do
    expect(dashboard["uid"]).to eq("reconaut-graph-retrieval")
    expect(dashboard["title"]).to eq("Reconaut — Graph Retrieval")
  end

  it "expose au moins un panel pour chaque métrique attendue" do
    panels = dashboard.fetch("panels")
    queries = panels.flat_map do |p|
      Array(p["targets"]).map { |t| t["expr"].to_s }
    end.join(" ")

    EXPECTED_METRICS.each do |metric|
      expect(queries).to include(metric),
                         "Aucun panel n'interroge la métrique `#{metric}`"
    end
  end

  it "chaque métrique référencée par un panel est émise par le code" do
    panels = dashboard.fetch("panels")
    metric_names = panels.flat_map do |p|
      Array(p["targets"]).map { |t| extract_metric_names(t["expr"].to_s) }
    end.flatten.uniq

    expect(metric_names).not_to be_empty

    metric_names.each do |metric|
      # `_bucket` / `_count` / `_sum` sont les suffixes Prometheus pour
      # les histograms ; le code émet la métrique de base.
      base = metric.sub(/_(bucket|count|sum)\z/, "")
      next if base.empty?

      regex = /[:\(]\s*:?#{Regexp.escape(base)}\b/
      expect(code_corpus).to match(regex),
                             "Métrique `#{base}` interrogée par un panel mais pas émise par le code applicatif (apps/api/app/lib/**/*.rb)"
    end
  end

  it "chaque panel a un titre non vide" do
    dashboard.fetch("panels").each do |p|
      next if p["type"] == "row"
      expect(p["title"].to_s).not_to be_empty,
                                     "Panel id=#{p['id']} sans titre"
    end
  end

  # Extrait les noms de métriques d'une PromQL minimale.
  # Pas un parser complet, juste suffisant pour les expressions du
  # dashboard (rate / sum by / histogram_quantile autour d'un nom de
  # métrique unique).
  def extract_metric_names(expr)
    expr.scan(/\b([a-z_][a-z_0-9]*?_(?:total|seconds|seconds_bucket|seconds_count|seconds_sum))\b/).flatten.uniq
  end
end
