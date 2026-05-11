# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Reconaut::EmbeddingIndexer : vectorise un Host (text fingerprint
# concaténant ip/fqdn + services) et insère/upsert dans la table
# `embeddings`.
#
# Cf. openspec/changes/add-embedding-pipeline/specs/agent-interface/spec.md
#   -> Requirement: Host Indexing Pipeline
#
# Idempotence stricte : un host = au plus une ligne d'embedding.
# Upsert sur `host_id`. Le `IndexHostJob` GoodJob retry-able peut donc
# ré-exécuter sans dupliquer.

module Reconaut
  module EmbeddingIndexer
    module_function

    # index! : indexe le host avec l'embedder courant et upsert la
    # ligne `embeddings`. Lève les erreurs embedder (Unavailable,
    # Timeout, CircuitOpen) — le caller (typiquement IndexHostJob) les
    # rattrape pour retry.
    def index!(host, embedder: ::Reconaut::Registry.default.embedder)
      text   = fingerprint_for(host)
      vector = embedder.embed(texts: [text]).first
      provider = embedder.respond_to?(:provider) ? embedder.provider : "unknown"
      dim      = embedder.respond_to?(:dim) ? embedder.dim : vector.length
      model    = "stub-#{dim}"

      row = ::Embedding.find_or_initialize_by(host_id: host.id)
      row.assign_attributes(
        content:    text,
        vector:     pg_vector_literal(vector),
        provider:   provider,
        model:      model,
        dim:        dim,
        indexed_at: Time.now.utc
      )
      row.save!
      row
    end

    # fingerprint_for : produit le texte à embedder pour un host.
    # Déterministe — mêmes inputs produisent le même texte.
    def fingerprint_for(host)
      parts = [host.ip, host.fqdn,
               "first_seen=#{host.first_seen_at}",
               "last_seen=#{host.last_seen_at}"]
      host.services.order(:port, :protocol).each do |s|
        banner_snip = s.banner.to_s[0, 200]
        parts << "service: port=#{s.port} protocol=#{s.protocol} banner=#{banner_snip}"
      end
      parts.compact.join("\n")
    end

    # pg_vector_literal : formatte un Array<Float> en littéral pgvector
    # (`[0.1,0.2,...]`). pgvector accepte ce format en littéral inséré
    # via les casts implicites de la colonne vector(N).
    def pg_vector_literal(arr)
      "[" + arr.map { |f| f.to_f.to_s }.join(",") + "]"
    end
  end
end
