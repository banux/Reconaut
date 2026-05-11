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
      checks << check_auth_storage(probes, ctx)
      checks << check_mcp_tls_posture(probes, ctx)
      checks << check_embedder_health(probes, ctx)
      checks << check_embedding_pipeline(probes, ctx)

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

    # auth_storage : backend choisi (active_record / in_memory) +
    # nombre de users et de clés API actives. Pour valider d'un coup
    # d'œil que la rake task `reconaut:set_password` et le serveur
    # voient bien la même base.
    #
    # Cf. openspec/changes/add-persistent-auth-storage/tasks.md §7.4.
    def check_auth_storage(_probes, _ctx)
      backend, users_count, keys_active = inspect_auth_storage
      Check.new(
        name:    "auth_storage",
        status:  :info,
        details: { backend: backend, users: users_count, api_keys_active: keys_active }
      )
    end

    # embedder_health : provider actif + dim + état du circuit breaker.
    # Cf. add-embedder-pluggable §5.1.
    def check_embedder_health(_probes, _ctx)
      embedder = ::Reconaut::Registry.default.embedder
      details = if embedder.respond_to?(:stats)
                  s = embedder.stats
                  {
                    provider:       s[:provider],
                    dim:            s[:dim],
                    circuit_state:  s[:circuit_state],
                    failures_total: s[:failures_total]
                  }
                else
                  {
                    provider:       embedder.provider,
                    dim:            embedder.dim,
                    circuit_state:  :closed, # Local n'est pas wrappé
                    failures_total: 0
                  }
                end
      Check.new(name: "embedder_health", status: :info, details: details)
    rescue StandardError => e
      Check.new(name: "embedder_health", status: :unknown, details: e.message[0, 80])
    end

    # embedding_pipeline : reporte indexed/total hosts + last_indexed_at.
    # Permet à l'opérateur de voir d'un coup d'œil si le pipeline
    # IndexHostJob est en retard ou si la table est vide.
    # Cf. add-embedding-pipeline §4.1.
    def check_embedding_pipeline(_probes, _ctx)
      return unknown_pipeline_check("modèle Embedding/Host absent") unless defined?(::Embedding) && defined?(::Host)
      return unknown_pipeline_check("table embeddings absente") unless ::Embedding.table_exists?

      indexed = ::Embedding.count
      total   = ::Host.count
      ratio   = total.zero? ? 1.0 : (indexed.to_f / total).round(2)
      last    = ::Embedding.maximum(:indexed_at)

      Check.new(
        name:    "embedding_pipeline",
        status:  :info,
        details: {
          indexed_hosts:   indexed,
          total_hosts:     total,
          ratio:           ratio,
          last_indexed_at: last&.utc&.iso8601
        }
      )
    rescue ::ActiveRecord::ActiveRecordError, ::PG::Error => e
      unknown_pipeline_check(e.message[0, 80])
    end

    def unknown_pipeline_check(reason)
      Check.new(name: "embedding_pipeline", status: :unknown, details: reason)
    end

    # mcp_tls_posture : valeur effective de RECONAUT_MCP_TLS_REQUIRED.
    # Cf. init-reconaut-platform §5.5 + line 236 acceptance.
    def check_mcp_tls_posture(_probes, _ctx)
      required = defined?(::Mcp::TlsPosture) ? ::Mcp::TlsPosture.required? : true
      Check.new(
        name:    "mcp_tls_posture",
        status:  :info,
        details: required ? "mcp.tls.required=true posture=internet-facing"
                          : "mcp.tls.required=false posture=internal"
      )
    end

    def inspect_auth_storage
      reg = ::Reconaut::Registry.default
      backend = if reg.user_store.is_a?(::Reconaut::Auth::Storage::ActiveRecordUsers)
                  "active_record"
                else
                  "in_memory"
                end

      users = reg.user_store.list.size
      keys_active = reg.api_key_store.list.count { |k| !k.revoked? }
      [backend, users, keys_active]
    rescue StandardError
      [backend || "unknown", nil, nil]
    end
  end
end
