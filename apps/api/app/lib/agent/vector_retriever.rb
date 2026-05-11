# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Agent::VectorRetriever : recherche par similarité cosine dans la
# table `embeddings` (pgvector + HNSW index). Branché dans le
# HybridRetriever via Reconaut::Agent::Pipeline.build.
#
# Cf. openspec/changes/add-embedding-pipeline/specs/agent-interface/spec.md
#   -> Requirement: VectorRetriever Backed by pgvector
#
# Mode mono-user strict : aucun filtre tenant_id.
#
# Comportement gracieux : embedder up → top-N hosts ; embedder down →
# propage UnavailableError/TimeoutError/CircuitOpenError (le caller —
# typiquement Mcp::ToolsController — mappe en 503). Table vide ou dim
# mismatch → retourne `[]` sans erreur.
module Agent
  class VectorRetriever
    DEFAULT_LIMIT = 50

    def initialize(embedder:, limit: DEFAULT_LIMIT)
      @embedder = embedder
      @limit    = limit
    end

    def call(query)
      q_vec   = @embedder.embed(texts: [query.to_s]).first
      literal = "[" + q_vec.map { |f| f.to_f.to_s }.join(",") + "]"

      conn = ::ActiveRecord::Base.connection
      sql  = ::ActiveRecord::Base.sanitize_sql_array([
        "SELECT host_id, indexed_at FROM embeddings ORDER BY vector <=> ?::vector LIMIT ?",
        literal, @limit
      ])
      rows = conn.execute(sql).to_a
      rows.map do |r|
        {
          "host_id"    => r["host_id"],
          "scanned_at" => format_iso(r["indexed_at"])
        }
      end
    rescue ::Reconaut::Embedder::UnavailableError,
           ::Reconaut::Embedder::TimeoutError,
           ::Reconaut::Embedder::CircuitOpenError
      raise # propage pour mapping 503 par Mcp::ToolsController
    rescue ::ActiveRecord::ActiveRecordError, ::PG::Error
      [] # gracieux : table vide, dim mismatch, ou DB absente
    end

    private

    def format_iso(value)
      return nil if value.nil?
      return value if value.is_a?(String)

      value.utc.iso8601
    end
  end
end
