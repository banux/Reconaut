# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "ingest_scan_result"

module Reconaut
  # ScanResultIngestor : service Ruby qui factorise la logique
  # « parse ScanResultV1 → upsert hosts/services/certs/sources ».
  # Appelé par le tool MCP `ingest_scan_result` (sources externes :
  # nmap, nuclei, etc.) ET par les workers Go (sources internes — le
  # worker peut soit écrire en DB directement, soit invoquer ce service
  # via une route interne ; les deux chemins partagent ce service pour
  # garantir un comportement identique).
  #
  # La factorisation est l'invariant central du change
  # `reposition-as-agent-knowledge-base` : peu importe d'où vient le
  # `ScanResultV1`, il passe par la même couche d'ingestion. C'est ce
  # qui permet le tagging `source` cohérent dans le graphe.
  #
  # Source de vérité :
  #   openspec/changes/reposition-as-agent-knowledge-base/specs/integrations/spec.md
  #   openspec/changes/reposition-as-agent-knowledge-base/tasks.md §2.2
  #
  # En v1, la persistance ActiveRecord (Hosts/Services/Certificates) sera
  # prise en charge par init-reconaut-platform §2.1. Pour l'instant, le
  # service délègue à `Reconaut::IngestScanResult` qui valide le payload,
  # vérifie le scope, applique l'idempotence et retourne un résultat
  # structuré. Quand les modèles AR seront livrés, on étendra ce service
  # en branchant les upserts SQL — sans toucher au tool MCP.
  module ScanResultIngestor
    SOURCE_INTERNAL = "internal"
    SOURCE_EXTERNAL = "external"

    module_function

    # Ingère un payload `ScanResultV1`. Retourne un Hash :
    #   { ok: true, outcome: "ingested" | "duplicate", idempotency_key:, source:, ... }
    #   { ok: false, error: "out-of-scope" | "invalid_payload", ... }
    #
    # `source_default` détermine la valeur de `source` quand le payload
    # n'en porte pas — typiquement "internal" pour un worker Go,
    # "external" pour le tool MCP.
    def call(payload:, scope_storage:, ingestion_recorder: nil, caller_id: "anonymous",
             source_default: SOURCE_EXTERNAL)
      effective_payload = payload.dup
      key_class = effective_payload.keys.first.is_a?(Symbol) ? :symbol : :string

      if read_source(effective_payload).to_s.strip.empty?
        write_source(effective_payload, source_default, key_class)
      end

      Reconaut::IngestScanResult.call(
        payload:            effective_payload,
        scope_storage:      scope_storage,
        ingestion_recorder: ingestion_recorder,
        caller_id:          caller_id
      )
    end

    # Liste agrégée et dédupliquée des sources observées pour un
    # idempotency_key donné. Sert au tagging `sources` côté graphe une
    # fois la persistance AR branchée. L'implémentation actuelle se
    # contente d'extraire la source du recorder en mémoire.
    def sources_for(ingestion_recorder, idem_key)
      return [] unless ingestion_recorder.respond_to?(:all)

      record = ingestion_recorder.all[idem_key]
      return [] unless record

      payload = record[:payload] || record["payload"]
      return [] unless payload

      [read_source(payload)].compact.uniq
    end

    def read_source(payload)
      payload["source"] || payload[:source]
    end

    def write_source(payload, value, key_class)
      if key_class == :symbol
        payload[:source] = value
      else
        payload["source"] = value
      end
    end
  end
end
