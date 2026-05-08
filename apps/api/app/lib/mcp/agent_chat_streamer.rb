# frozen_string_literal: true

# Découpe une `Agent::HybridRetriever::Response` en chunks "tool_result"
# partiels destinés au transport MCP HTTP+SSE. Chaque chunk est un Hash
# auto-contenu : un consommateur peut concaténer les `result.rows` /
# `result.citations` de tous les chunks pour reconstituer la réponse
# entière.
#
# Forme des chunks émis (ordre garanti) :
#   1. { type: "start", retrieval_path:, duration_ms: }
#   2..N. { type: "row", row: {...}, citation: {host_id, scanned_at, source} }
#   N+1. { type: "done", warnings: [...], total_rows: N }
#
# La concaténation des `row` produit `response.rows` et la concaténation
# des `citation` produit `response.citations` (cf. test plan §1.2).
#
# Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
# (Requirement: MCP Tool Surface — agent_chat streaming).
module Mcp
  module AgentChatStreamer
    module_function

    def chunks_for(response)
      chunks = []
      chunks << {
        type:           "start",
        retrieval_path: response.retrieval_path,
        duration_ms:    response.duration_ms
      }

      citations_by_host = response.citations.each_with_object({}) do |c, acc|
        acc[c.host_id] = c.to_h
      end

      Array(response.rows).each do |row|
        host_id  = row.is_a?(Hash) ? (row["host_id"] || row[:host_id]) : nil
        citation = citations_by_host[host_id]
        chunks << {
          type:     "row",
          row:      row,
          citation: citation
        }
      end

      chunks << {
        type:       "done",
        warnings:   Array(response.warnings),
        total_rows: Array(response.rows).size
      }
      chunks
    end
  end
end
