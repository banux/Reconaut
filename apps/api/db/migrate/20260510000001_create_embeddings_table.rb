# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Crée la table `embeddings` (vecteurs sémantiques par hôte) avec un
# index HNSW pgvector (cosine).
#
# Cf. openspec/changes/add-embedder-pluggable/specs/agent-interface/spec.md
#   -> Requirement: Vector Storage with pgvector + HNSW
#
# Dimension figée à 384 par défaut (alignée sur
# Reconaut::Embedder::DEFAULT_LOCAL_DIM). Un opérateur qui change de
# provider avec une dim différente DOIT re-vectoriser via une migration
# custom — documenté dans docs/operating/embedder-providers.md.
class CreateEmbeddingsTable < ActiveRecord::Migration[8.1]
  def up
    # Extension `vector` est déjà activée par enable_graph_extensions.
    # Modèle mono-user, cf. single-user-only — aucun discriminant
    # multi-tenant.
    create_table :embeddings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :host, type: :uuid, null: false,
                          foreign_key: { on_delete: :cascade },
                          index: { name: "idx_embeddings_host_id" }
      t.text   :content,   null: false
      t.column :vector,    "vector(384)", null: false
      t.string :provider,  null: false, limit: 32
      t.string :model,     null: false, limit: 128
      t.integer :dim,      null: false
      t.timestamp :indexed_at, null: false, default: -> { "now()" }
    end

    add_check_constraint :embeddings,
                         "provider IN ('local','ollama','mistral','openai-compatible')",
                         name: "embeddings_provider_chk"
    add_check_constraint :embeddings,
                         "dim > 0 AND dim <= 4096",
                         name: "embeddings_dim_chk"

    # Index HNSW pgvector pour ORDER BY vector <=> $1 LIMIT N en O(log N).
    # `m` et `ef_construction` aux defaults pgvector ; ajustables si
    # le rappel/perf devient un problème (~1M vecteurs).
    execute <<~SQL.squish
      CREATE INDEX idx_embeddings_vector_hnsw
        ON embeddings USING hnsw (vector vector_cosine_ops)
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS idx_embeddings_vector_hnsw"
    drop_table :embeddings
  end
end
