# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "uri"
require "openssl"
require_relative "tool_registry"
require_relative "../agent/hybrid_retriever"
require_relative "../reconaut/scan_enqueuer"
require_relative "../reconaut/doctor"
require_relative "../reconaut/heartbeats"
require_relative "../reconaut/scans"
require_relative "../reconaut/ingest_scan_result"
require_relative "../reconaut/exporter"
require_relative "../../use_cases/scopes/list"
require_relative "../../use_cases/scopes/add"
require_relative "../../use_cases/scopes/revoke"
require_relative "../../use_cases/scanner/claim_job"
require_relative "../../use_cases/scanner/submit_result"
require_relative "../../use_cases/scanner/fail_job"

module Mcp
  # Set initial d'outils MCP (read-only en priorite). Les outils
  # mutants (request_scan) viendront aux iterations suivantes une fois
  # GoodJob cable.
  #
  # Cf. openspec/changes/init-reconaut-platform/specs/mcp-server/spec.md
  # et tasks.md sections 5.1 / 5.3 (scopes par outil).
  # Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
  # (extension de la surface de tools : system_doctor en v1).
  module CoreTools
    module_function

    def register_all!(retriever:, scope_storage:, scan_enqueuer: nil,
                      doctor: Reconaut::Doctor, doctor_probes: {}, doctor_env: ENV.to_h,
                      api_key_storage: nil,
                      ingestion_recorder: nil,
                      heartbeat_store: nil,
                      scan_store: nil)
      ToolRegistry.reset!

      # search_hosts : delegue au HybridRetriever, expose les rows + warnings.
      ToolRegistry.register(
        name:   "search_hosts",
        scopes: [:"read:hosts"],
        params_schema: {
          query: { type: :string, min_length: 1, max_length: 1000 },
          limit: { type: :integer, required: false, default: 50, min: 1, max: 100 }
        }
      ) do |params:, caller_id:|
        result = retriever.call(params[:query])
        rows = Array(result.rows).first(params[:limit])
        {
          rows:           rows,
          citations:      result.citations.map(&:to_h),
          warnings:       result.warnings,
          retrieval_path: result.retrieval_path
        }
      end

      # get_host : lookup ponctuel par host_id. La v1 le sert depuis
      # le retriever en passant l'id comme query exacte (le pipeline
      # graphe matche via host_neighborhood). Quand un index dedie
      # existera, on switchera ici.
      ToolRegistry.register(
        name:   "get_host",
        scopes: [:"read:hosts"],
        params_schema: {
          host_id: { type: :string, min_length: 1, max_length: 64 }
        }
      ) do |params:, caller_id:|
        result = retriever.call("host_id:#{params[:host_id]}")
        host_row = Array(result.rows).find do |row|
          (row.is_a?(Hash) ? (row["host_id"] || row[:host_id]) : nil) == params[:host_id]
        end
        if host_row.nil?
          { found: false, host_id: params[:host_id] }
        else
          { found: true, host: host_row, citations: result.citations.map(&:to_h) }
        end
      end

      # list_scopes : utile aux agents externes pour comprendre le
      # perimetre declare avant d'appeler request_scan.
      ToolRegistry.register(
        name:   "list_scopes",
        scopes: [:"read:scopes"],
        params_schema: {}
      ) do |params:, caller_id:|
        scopes = scope_storage.list.map(&:to_h)
        { scopes: scopes }
      end

      # add_scope : ajoute une entrée de scope (cidr / domain / ip / host)
      # via le use case Scopes::Add. Le contrôle d'accès est porté par
      # le scope MCP `write:scopes` ; le use case ne vérifie plus de
      # rôle (cf. openspec/changes/single-user-only/).
      ToolRegistry.register(
        name:   "add_scope",
        scopes: [:"write:scopes"],
        params_schema: {
          kind:  { type: :enum, values: %w[ip cidr domain host] },
          value: { type: :string, min_length: 1, max_length: 255 }
        }
      ) do |params:, caller_id:|
        result = Scopes::Add
                   .new(storage: scope_storage)
                   .call(
                     kind:      params[:kind],
                     value:     params[:value],
                     caller_id: caller_id
                   )
        case result.status
        when :created
          { ok: true, scope: result.body[:scope] }
        when :bad_request
          { ok: false, error: "invalid_param", message: result.body[:error] }
        else
          { ok: false, error: result.body.is_a?(Hash) ? result.body[:error] : "unknown" }
        end
      end

      # revoke_scope : marque une entrée de scope comme revoked.
      ToolRegistry.register(
        name:   "revoke_scope",
        scopes: [:"write:scopes"],
        params_schema: {
          id: { type: :string, min_length: 1, max_length: 64 }
        }
      ) do |params:, caller_id:|
        result = Scopes::Revoke
                   .new(storage: scope_storage)
                   .call(
                     id:        params[:id],
                     caller_id: caller_id
                   )
        case result.status
        when :no_content
          { ok: true, id: params[:id] }
        when :not_found
          { ok: false, error: "scope_not_found", id: params[:id] }
        else
          { ok: false, error: result.body.is_a?(Hash) ? result.body[:error] : "unknown" }
        end
      end

      # request_scan : valide le scope, enqueue un job ScanJobV1 dans la
      # file (GoodJob en prod, InMemory en tests). Renvoie le scan_id en
      # < 100 ms (l'enqueue est synchrone, le scan est asynchrone).
      if scan_enqueuer
        ToolRegistry.register(
          name:   "request_scan",
          scopes: [:"write:scans"],
          params_schema: {
            scan_kind:    { type: :enum, values: %w[tcp_probe tls_capture http_banner subdomain_enum service_fingerprint dns_records] },
            target_kind:  { type: :enum, values: %w[ip cidr domain host] },
            target_value: { type: :string, min_length: 1, max_length: 255 }
          }
        ) do |params:, caller_id:|
          begin
            result = scan_enqueuer.call(
              scan_kind:    params[:scan_kind],
              target_kind:  params[:target_kind],
              target_value: params[:target_value]
            )
            { ok: true, scan_id: result.scan_id, idempotency_key: result.idempotency_key }
          rescue Reconaut::ScanEnqueuer::InvalidTargetError => e
            { ok: false, error: "invalid_target", message: e.message }
          rescue Reconaut::ScanEnqueuer::OutOfScopeError => e
            { ok: false, error: "out-of-scope", message: e.message }
          rescue Reconaut::ScanEnqueuer::InvalidPayloadError => e
            { ok: false, error: "invalid_payload", message: e.message }
          end
        end
      end

      # list_scans : liste les scans connus (du plus récent au plus
      # ancien) avec leur status courant. Lecture seule.
      # Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
      # (Requirement: MCP Tool Surface, scope read:scans).
      if scan_store
        ToolRegistry.register(
          name:   "list_scans",
          scopes: [:"read:scans"],
          params_schema: {
            limit: { type: :integer, required: false, default: 50, min: 1, max: 200 }
          }
        ) do |params:, caller_id:|
          records = scan_store.list(limit: params[:limit])
          { scans: records.map(&:to_h) }
        end

        # get_scan_status : lookup ponctuel par scan_id. Renvoie
        # `{ found: false }` quand le scan n'existe pas (ou plus, si on
        # ajoute de la TTL plus tard).
        ToolRegistry.register(
          name:   "get_scan_status",
          scopes: [:"read:scans"],
          params_schema: {
            scan_id: { type: :string, min_length: 1, max_length: 64 }
          }
        ) do |params:, caller_id:|
          record = scan_store.find(params[:scan_id])
          if record.nil?
            { found: false, scan_id: params[:scan_id] }
          else
            { found: true, scan: record.to_h }
          end
        end
      end

      # agent_chat : delegue au pipeline HybridRetriever et renvoie une
      # reponse synchrone (rows + citations). Le streaming via
      # tool_result partiels SSE est gere cote controller (cf. §1.2),
      # mais l'outil expose deja la sémantique : un appel = une
      # reponse complete avec citations (host_id, scanned_at).
      #
      # Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
      # (Requirement: MCP Tool Surface, scope agent:chat).
      ToolRegistry.register(
        name:   "agent_chat",
        scopes: [:"agent:chat"],
        params_schema: {
          prompt:  { type: :string, min_length: 1, max_length: 4000 },
          context: { type: :hash, required: false, default: {} }
        }
      ) do |params:, caller_id:|
        response = retriever.call(params[:prompt])
        {
          rows:           response.rows,
          citations:      response.citations.map(&:to_h),
          warnings:       response.warnings,
          retrieval_path: response.retrieval_path,
          duration_ms:    response.duration_ms
        }
      end

      # ingest_scan_result : surface d'integration entrante. Accepte
      # un payload conforme ScanResultV1 provenant d'un outil externe
      # (nmap, nuclei, etc.) et l'ingere dans la base de connaissance.
      # Le payload est valide contre le schema canonique ; la cible est
      # verifiee contre le scope declare ; l'idempotency_key permet la
      # deduplication. Cf. openspec/changes/reposition-as-agent-knowledge-base/.
      ToolRegistry.register(
        name:   "ingest_scan_result",
        scopes: [:"write:scans"],
        params_schema: {
          payload: { type: :hash }
        }
      ) do |params:, caller_id:|
        Reconaut::IngestScanResult.call(
          payload:            params[:payload],
          scope_storage:      scope_storage,
          ingestion_recorder: ingestion_recorder,
          caller_id:          caller_id
        )
      end

      # system_doctor : expose le rapport Reconaut::Doctor comme outil
      # MCP. Permet a la TUI (reconautctl doctor) et aux agents IA
      # d'auditer la sante d'une instance via le canal canonique MCP,
      # sans dupliquer la logique du rake task reconaut:doctor.
      #
      # Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
      # (Requirement: MCP Tool Surface, scope read:health).
      ToolRegistry.register(
        name:   "system_doctor",
        scopes: [:"read:health"],
        params_schema: {}
      ) do |params:, caller_id:|
        report = doctor.run(probes: doctor_probes, env: doctor_env)
        report.to_h
      end

      # submit_heartbeat : reçoit un payload HeartbeatV1 émis par un
      # worker Go. Validé contre le schema canonique. Le résultat
      # alimente le probe Doctor `last_worker_heartbeat`.
      # Cf. openspec/changes/add-tech-stack/tasks.md section 6.
      if heartbeat_store
        ToolRegistry.register(
          name:   "submit_heartbeat",
          scopes: [:"write:heartbeats"],
          params_schema: {
            payload: { type: :hash }
          }
        ) do |params:, caller_id:|
          payload = params[:payload]
          ok, errors = JobSchema::Registry.validate("HeartbeatV1", payload)
          if ok
            record = heartbeat_store.record!(payload)
            { ok: true, recorded: record.to_h }
          else
            { ok: false, error: "invalid_payload", errors: errors }
          end
        end
      end

      # API key tools : list_api_keys et revoke_api_key. En mode
      # mono-user (cf. openspec/changes/single-user-only/), le tool
      # list_users a ete retire (un seul operateur, pas de personnes a
      # lister) et list_api_keys ne prend plus de parametre user_id —
      # toutes les cles appartiennent au meme operateur unique.
      if api_key_storage
        ToolRegistry.register(
          name:   "list_api_keys",
          scopes: [:"read:api_keys"],
          params_schema: {}
        ) do |params:, caller_id:|
          { api_keys: api_key_storage.list.map(&:to_h) }
        end

        ToolRegistry.register(
          name:   "revoke_api_key",
          scopes: [:"write:api_keys"],
          params_schema: {
            id: { type: :string, min_length: 1, max_length: 64 }
          }
        ) do |params:, caller_id:|
          revoked = api_key_storage.revoke!(params[:id])
          if revoked.nil?
            { ok: false, error: "api_key_not_found", id: params[:id] }
          else
            { ok: true, api_key: revoked.to_h }
          end
        end
      end

      register_export_report!

      # claim_scan_job / submit_scan_result / fail_scan_job : permettent
      # à un worker distant (sans accès Postgres) de réclamer son
      # prochain job et de remonter son résultat via MCP HTTP.
      # Cf. openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
      ToolRegistry.register(
        name:   "claim_scan_job",
        scopes: [:"worker:claim"],
        params_schema: {
          queue:         { type: :string, min_length: 1, max_length: 64 },
          worker_id:     { type: :string, min_length: 1, max_length: 128 },
          lease_seconds: { type: :integer, required: false, default: 300, min: 1, max: 1800 }
        }
      ) do |params:, caller_id:|
        result = Scanner::ClaimJob.new(
          scope_storage: scope_storage,
          audit_recorder: ingestion_recorder
        ).call(
          queue:         params[:queue],
          worker_id:     params[:worker_id],
          lease_seconds: params[:lease_seconds],
          caller_id:     caller_id
        )
        result.body
      end

      ToolRegistry.register(
        name:   "submit_scan_result",
        scopes: [:"worker:submit"],
        params_schema: {
          job_id:          { type: :string, min_length: 1, max_length: 64 },
          idempotency_key: { type: :string, min_length: 1, max_length: 128 },
          scan_kind:       { type: :string, min_length: 1, max_length: 64 },
          target_kind:     { type: :string, min_length: 1, max_length: 32 },
          target_value:    { type: :string, min_length: 1, max_length: 255 },
          status:          { type: :string, min_length: 1, max_length: 65_535 },
          observed_at:     { type: :string, min_length: 10, max_length: 64 }
        }
      ) do |params:, caller_id:|
        result = Scanner::SubmitResult.new(audit_recorder: ingestion_recorder).call(
          job_id:          params[:job_id],
          idempotency_key: params[:idempotency_key],
          scan_kind:       params[:scan_kind],
          target_kind:     params[:target_kind],
          target_value:    params[:target_value],
          status:          params[:status],
          observed_at:     params[:observed_at],
          caller_id:       caller_id
        )
        case result.status
        when :ok
          { ok: true }
        when :bad_request
          { ok: false, error: result.body[:error] }
        else
          { ok: false, error: "unknown" }
        end
      end

      ToolRegistry.register(
        name:   "fail_scan_job",
        scopes: [:"worker:submit"],
        params_schema: {
          job_id: { type: :string, min_length: 1, max_length: 64 },
          error:  { type: :string, min_length: 1, max_length: 1024 }
        }
      ) do |params:, caller_id:|
        Scanner::FailJob.new(audit_recorder: ingestion_recorder).call(
          job_id:    params[:job_id],
          error:     params[:error],
          caller_id: caller_id
        ).body
      end

      ToolRegistry
    end

    # export_report : génère un export json/csv/stix2, retourne une URL
    # de téléchargement signée HMAC-SHA256 (one-shot, TTL 1h).
    #
    # Cf. openspec/changes/add-mcp-engine/specs/mcp-server/spec.md
    #   -> Requirement: MCP Tool `export_report`
    def register_export_report!
      ToolRegistry.register(
        name:   "export_report",
        scopes: [:"read:reports"],
        params_schema: {
          filter: { type: :hash },
          format: { type: :string, min_length: 3, max_length: 16 }
        }
      ) do |params:, caller_id:|
        filter = params[:filter] || {}
        format = params[:format].to_s
        kind   = (filter[:kind] || filter["kind"]).to_s
        limit  = (filter[:limit] || filter["limit"] || ::Reconaut::Exporter::DEFAULT_LIMIT).to_i

        unless ::Reconaut::Exporter::ALLOWED_KINDS.include?(kind)
          next { ok: false, error: "invalid_param", message: "filter.kind must be one of #{::Reconaut::Exporter::ALLOWED_KINDS.join(", ")}" }
        end
        unless ::Reconaut::Exporter::ALLOWED_FORMATS.include?(format)
          next { ok: false, error: "invalid_param", message: "format must be one of #{::Reconaut::Exporter::ALLOWED_FORMATS.join(", ")}" }
        end

        dest_dir   = export_dir
        ttl_s      = export_ttl_s
        ::Reconaut::Exporter.purge_older_than!(dir: dest_dir, older_than: 24 * 3600)

        begin
          result = ::Reconaut::Exporter.export(
            kind: kind, format: format, dest_dir: dest_dir, limit: limit
          )
        rescue ::Reconaut::Exporter::InvalidParamError => e
          next { ok: false, error: "invalid_param", message: e.message }
        rescue ::ActiveRecord::ActiveRecordError, PG::Error => e
          # DB indisponible / table absente — retombe gracieusement.
          next { ok: false, error: "data_unavailable", message: e.class.name }
        end

        uuid       = File.basename(result.path, ".*")
        expires_at = (Time.now + ttl_s).utc.iso8601
        token      = export_token_for(uuid, expires_at)

        # download_url embarque les deux paramètres signés ; le client
        # fait un GET direct sans avoir à reconstruire l'URL.
        query = ::URI.encode_www_form(token: token, expires_at: expires_at)

        {
          download_url:  "/mcp/exports/#{uuid}?#{query}",
          token:         token,
          expires_at:    expires_at,
          format:        result.format,
          record_count:  result.record_count,
          kind:          result.kind
        }
      end
    end

    # Token HMAC-SHA256 calculé sur "<uuid>|<expires_at>" avec
    # `Rails.application.secret_key_base`. Vérifié au temps constant
    # via `Rack::Utils.secure_compare` côté ExportsController.
    def export_token_for(uuid, expires_at_iso)
      secret = ::Rails.application.secret_key_base
      ::OpenSSL::HMAC.hexdigest("SHA256", secret, "#{uuid}|#{expires_at_iso}")
    end

    def export_dir
      path = ENV["RECONAUT_EXPORT_DIR"]
      path = ::Rails.root.join("tmp/exports").to_s if path.nil? || path.empty?
      path
    end

    def export_ttl_s
      Integer(ENV.fetch("RECONAUT_EXPORT_TTL_S", 3600))
    end
  end
end
