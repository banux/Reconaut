# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "../job_schema/registry"

module Reconaut
  # IngestScanResult : logique de l'outil MCP ingest_scan_result
  # extraite du registry pour permettre les retours intermediaires
  # propres (les blocs Ruby et `next` se melangent mal avec les hash
  # litteraux). Module fonctionnel pur — pas d'etat conserve, pas de
  # side effect en dehors du `ingestion_recorder` injecte.
  #
  # Cf. openspec/changes/reposition-as-agent-knowledge-base/specs/integrations/spec.md
  # (Requirement: Inbound Integration via ScanResultV1).
  module IngestScanResult
    module_function

    def call(payload:, scope_storage:, ingestion_recorder:, caller_id:)
      ok, errors = JobSchema::Registry.validate("ScanResultV1", payload)
      return invalid_payload(errors) unless ok

      target_kind, target_value = extract_target(payload)
      return out_of_scope(target_kind, target_value) unless in_scope?(scope_storage, target_kind, target_value)

      idem_key = payload["idempotency_key"] || payload[:idempotency_key]
      if ingestion_recorder && ingestion_recorder.seen?(idem_key)
        return duplicate(idem_key)
      end

      ingestion_recorder&.record!(idem_key, payload: payload, caller_id: caller_id)

      ingested(payload, idem_key)
    end

    def extract_target(payload)
      target = payload["target"] || payload[:target] || {}
      [target["kind"] || target[:kind], target["value"] || target[:value]]
    end

    def in_scope?(scope_storage, kind, value)
      scope_storage.list.any? do |scope|
        scope.kind.to_s == kind.to_s && scope.value.to_s == value.to_s
      end
    end

    def invalid_payload(errors)
      { ok: false, error: "invalid_payload", errors: errors }
    end

    def out_of_scope(kind, value)
      { ok: false, error: "out-of-scope", target: { kind: kind, value: value } }
    end

    def duplicate(key)
      { ok: true, outcome: "duplicate", idempotency_key: key }
    end

    # En v1, la persistance reelle (hosts/services/certs ActiveRecord)
    # sera prise en charge par un futur service ScanResultIngestor une
    # fois les modeles AR crees par init-reconaut-platform 2.1. Pour
    # l'instant, on accuse reception et on retourne les coordonnees
    # de correlation (idempotency_key, job_id, source).
    def ingested(payload, idem_key)
      {
        ok:              true,
        outcome:         "ingested",
        idempotency_key: idem_key,
        job_id:          payload["job_id"] || payload[:job_id],
        source:          payload["source"] || payload[:source] || "external"
      }
    end
  end
end
