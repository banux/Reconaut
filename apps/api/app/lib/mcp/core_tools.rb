# frozen_string_literal: true

require_relative "tool_registry"
require_relative "../agent/hybrid_retriever"
require_relative "../reconaut/scan_enqueuer"
require_relative "../reconaut/doctor"
require_relative "../../use_cases/scopes/operations"

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
                      doctor: Reconaut::Doctor, doctor_probes: {}, doctor_env: ENV.to_h)
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

      # request_scan : valide le scope, enqueue un job ScanJobV1 dans la
      # file (GoodJob en prod, InMemory en tests). Renvoie le scan_id en
      # < 100 ms (l'enqueue est synchrone, le scan est asynchrone).
      if scan_enqueuer
        ToolRegistry.register(
          name:   "request_scan",
          scopes: [:"write:scans"],
          params_schema: {
            scan_kind:    { type: :enum, values: %w[tcp_probe tls_capture http_banner subdomain_enum service_fingerprint] },
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
          rescue Reconaut::ScanEnqueuer::OutOfScopeError => e
            { ok: false, error: "out-of-scope", message: e.message }
          rescue Reconaut::ScanEnqueuer::InvalidPayloadError => e
            { ok: false, error: "invalid_payload", message: e.message }
          end
        end
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

      ToolRegistry
    end
  end
end
