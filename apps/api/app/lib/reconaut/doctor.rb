# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

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
    # NOTE: l'ancienne `EU_REGION_ALLOWLIST` a été retirée par le change
    # `drop-gdpr-framing`. La résidence des données est désormais une
    # **étiquette de souveraineté libre** (chaîne quelconque) que
    # l'opérateur déclare via `RECONAUT_DATA_RESIDENCY`. Aucune
    # validation EU n'est faite côté projet.

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
      graph_role_can_write?:   ->(_) { true }, # par securite, fail closed.
      # Probes "info" pour l'acceptance criterion bin/doctor de
      # add-tech-stack section 6 : version Rails, taille file good_jobs,
      # versions de schema cote Rails et derniere heartbeat worker Go.
      rails_version:           ->(_) { defined?(Rails) ? Rails.version : nil },
      good_jobs_pending:       ->(_) { nil },
      schema_versions:         ->(_) { safe_schema_versions },
      last_worker_heartbeat:   ->(_) { nil },
      # Probe d'intégration entrante : vérifie que le tool MCP
      # `ingest_scan_result` est bien enregistré au boot. Cf. change
      # `reposition-as-agent-knowledge-base` §4.4.
      ingest_tool_registered?: ->(_) { defined?(Mcp::ToolRegistry) && Mcp::ToolRegistry.names.include?("ingest_scan_result") }
    }.freeze

    module_function

    # safe_schema_versions : evite de planter au boot si JobSchema n'est
    # pas chargeable (par ex. tests Doctor isoles sans Rails autoload).
    def safe_schema_versions
      require_relative "../job_schema/registry"
      JobSchema::Registry.schema_versions
    rescue StandardError
      nil
    end

    def run(probes: {}, env: ENV)
      probes = DEFAULTS.merge(probes)
      ctx    = { env: env }
      checks = []

      checks << check_age(probes, ctx)
      checks << check_data_residency(probes, ctx)
      checks << check_graph_lag(probes, ctx)
      checks << check_graph_role(probes, ctx)
      checks << check_external_llm(probes, ctx)
      checks << check_rails_version(probes, ctx)
      checks << check_good_jobs(probes, ctx)
      checks << check_schema_versions(probes, ctx)
      checks << check_last_worker(probes, ctx)
      checks << check_ingestion_endpoint(probes, ctx)

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

    # check_region a été remplacé par check_data_residency : étiquette
    # de souveraineté libre, info-level seulement, jamais de fail.
    # Cf. change `drop-gdpr-framing`.
    def check_data_residency(probes, ctx)
      label = probes[:region].call(ctx)
      if label.nil? || label.to_s.strip.empty?
        Check.new(
          name:    "data_residency",
          status:  :unknown,
          details: "résidence non déclarée — l'opérateur peut la déclarer via RECONAUT_DATA_RESIDENCY"
        )
      else
        Check.new(
          name:    "data_residency",
          status:  :info,
          details: "résidence déclarée : #{label}"
        )
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

    def check_rails_version(probes, ctx)
      version = probes[:rails_version].call(ctx)
      Check.new(
        name:    "rails_version",
        status:  version ? :info : :unknown,
        details: version ? version.to_s : "Rails non charge"
      )
    end

    def check_good_jobs(probes, ctx)
      pending = probes[:good_jobs_pending].call(ctx)
      if pending.nil?
        Check.new(
          name: "good_jobs_pending",
          status: :unknown,
          details: "DB indisponible ou table good_jobs non creee"
        )
      else
        Check.new(
          name: "good_jobs_pending",
          status: :info,
          details: "#{Integer(pending)} job(s) en attente"
        )
      end
    end

    def check_schema_versions(probes, ctx)
      versions = probes[:schema_versions].call(ctx)
      if versions.nil? || versions.empty?
        Check.new(
          name: "schema_versions_rails",
          status: :unknown,
          details: "schemas job-schema introuvables"
        )
      else
        pretty = versions.map { |k, v| "#{k}=v#{v}" }.join(", ")
        Check.new(
          name:    "schema_versions_rails",
          status:  :info,
          details: pretty
        )
      end
    end

    def check_last_worker(probes, ctx)
      heartbeat = probes[:last_worker_heartbeat].call(ctx)
      if heartbeat.nil?
        Check.new(
          name: "last_worker_heartbeat",
          status: :unknown,
          details: "aucune heartbeat enregistree (worker pas encore connecte ?)"
        )
      else
        worker_version  = heartbeat[:worker_version] || heartbeat["worker_version"]
        schema_version  = heartbeat[:schema_version] || heartbeat["schema_version"]
        seen_at         = heartbeat[:seen_at]        || heartbeat["seen_at"]
        Check.new(
          name:    "last_worker_heartbeat",
          status:  :info,
          details: "worker_version=#{worker_version || 'n/a'}, schema_version=#{schema_version || 'n/a'}, seen_at=#{seen_at || 'n/a'}"
        )
      end
    end

    # Vérifie que le tool MCP `ingest_scan_result` est bien enregistré
    # au boot. Statut `:info` (présent) ou `:unknown` (registry vide,
    # par ex. en test isolé). Pas de `:fail` : un opérateur peut
    # délibérément ne pas exposer le tool d'ingestion (clé full-scope
    # personnelle uniquement).
    def check_ingestion_endpoint(probes, ctx)
      registered = probes[:ingest_tool_registered?].call(ctx)
      if registered
        Check.new(
          name:    "ingestion_endpoint_reachable",
          status:  :info,
          details: "tool MCP `ingest_scan_result` enregistré"
        )
      else
        Check.new(
          name:    "ingestion_endpoint_reachable",
          status:  :unknown,
          details: "tool MCP `ingest_scan_result` non enregistré (registry vide ?)"
        )
      end
    end
  end
end
