# frozen_string_literal: true

require_relative "embedder"

module Reconaut
  # Reconaut::Doctor : routine de self-check appelable par
  # `bin/rails reconaut:doctor` ou par un test e2e.
  #
  # Source de verite :
  #   openspec/changes/add-tech-stack/tasks.md section 6 (bin/doctor
  #     -> Rake task rails reconaut:doctor)
  #   openspec/changes/add-graph-retrieval/tasks.md section 7.1
  #
  # La routine prend une "config" injectable (probes vers la DB,
  # variables d'environnement, etc.) et renvoie un Report structure :
  #   { ok: bool, checks: [{name, status, details}] }
  #
  # Les "probes" sont des callables qu'on remplace en tests pour
  # simuler une DB EU / non-EU, AGE absent, embedder externe configure,
  # etc., sans avoir a booter Postgres.
  module Doctor
    EU_REGION_ALLOWLIST = %w[
      eu-west-1 eu-west-2 eu-west-3
      eu-central-1 eu-central-2
      eu-north-1 eu-south-1 eu-south-2
      europe-west1 europe-west2 europe-west3 europe-west4
      europe-west6 europe-west8 europe-west9
      europe-central2 europe-north1
      fr-par fr-par-1 fr-par-2 nl-ams pl-waw
      eu-de-1 eu-fr-1
      eu-1 eu-2
    ].freeze

    Check = Struct.new(:name, :status, :details, keyword_init: true) do
      def ok?      = status == :ok
      def to_h     = { name: name, status: status, details: details }
    end

    Report = Struct.new(:ok, :checks, keyword_init: true) do
      def to_h = { ok: ok, checks: checks.map(&:to_h) }

      def exit_code = ok ? 0 : 1
    end

    # Probes : objets fournis par l'appelant. Contrat informel :
    #   probes[:age_loaded?]     -> true/false (extension AGE chargee)
    #   probes[:region]          -> String (region declaree)
    #   probes[:graph_lag_p95]   -> Numeric (secondes) ou nil
    #   probes[:graph_role_can_write?] -> true/false
    # Le probe[:env] retourne le hash d'env utilise pour decider du
    # provider d'embedder.
    DEFAULTS = {
      age_loaded?:             ->(_) { false },
      region:                  ->(_) { nil },
      graph_lag_p95:           ->(_) { nil },
      graph_role_can_write?:   ->(_) { true } # par securite, fail closed.
    }.freeze

    module_function

    def run(probes: {}, env: ENV)
      probes = DEFAULTS.merge(probes)
      ctx    = { env: env }
      checks = []

      checks << check_age(probes, ctx)
      checks << check_region(probes, ctx)
      checks << check_graph_lag(probes, ctx)
      checks << check_graph_role(probes, ctx)
      checks << check_external_llm(probes, ctx)

      # ok = aucun :fail. Les statuts :info (provider externe configure)
      # et :unknown (lag pas encore mesure, normal au boot) sont
      # informatifs, pas bloquants.
      Report.new(
        ok: checks.none? { |c| c.status == :fail },
        checks: checks
      )
    end

    def check_age(probes, ctx)
      if probes[:age_loaded?].call(ctx)
        Check.new(name: "graph_tier", status: :ok, details: "AGE loaded")
      else
        Check.new(name: "graph_tier", status: :fail,
                  details: "graph-extension-missing: Apache AGE n'est pas charge")
      end
    end

    def check_region(probes, ctx)
      region = probes[:region].call(ctx)
      if region.nil? || region.to_s.strip.empty?
        return Check.new(name: "region", status: :fail,
                         details: "graph-region-unknown: region non declaree")
      end
      if EU_REGION_ALLOWLIST.include?(region.to_s)
        Check.new(name: "region", status: :ok, details: region.to_s)
      else
        Check.new(name: "region", status: :fail,
                  details: "graph-region-not-allowed: #{region.inspect} hors EU/EEE")
      end
    end

    def check_graph_lag(probes, ctx)
      lag = probes[:graph_lag_p95].call(ctx)
      if lag.nil?
        # Pas encore de donnee de lag : on ne fail pas, on warn.
        return Check.new(name: "graph_lag", status: :unknown,
                         details: "pas de mesure recente de graph_lag_seconds")
      end
      if lag.to_f <= 60.0
        Check.new(name: "graph_lag", status: :ok,
                  details: "graph_lag p95=#{lag.to_f.round(1)}s (cible < 60s)")
      else
        Check.new(name: "graph_lag", status: :fail,
                  details: "graph-lag-too-high: p95=#{lag}s")
      end
    end

    def check_graph_role(probes, ctx)
      can_write = probes[:graph_role_can_write?].call(ctx)
      if can_write
        Check.new(name: "graph_role_reader", status: :fail,
                  details: "graph-reader-can-write: le role reader peut ecrire dans le graphe")
      else
        Check.new(name: "graph_role_reader", status: :ok,
                  details: "reader sans privilege d'ecriture")
      end
    end

    def check_external_llm(_probes, ctx)
      provider = (ctx[:env]["RECONAUT_EMBEDDER_PROVIDER"] || "local").to_s.downcase
      external = !%w[local].include?(provider)
      Check.new(
        name: "external_llm_required",
        status: external ? :info : :ok,
        details: external ? "provider=#{provider} (sortance reseau requise)" : "false (instance auto-suffisante)"
      )
    end
  end
end
