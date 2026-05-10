# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Modèle ActiveRecord mappant la table `embeddings` (vecteurs
# sémantiques par hôte). La logique de résilience et d'appels embedder
# vit dans `Reconaut::Embedder::*` ; ce modèle n'est qu'une couche de
# persistance.
#
# Cf. openspec/changes/add-embedder-pluggable/specs/agent-interface/spec.md
#   -> Requirement: Vector Storage with pgvector + HNSW
class Embedding < ApplicationRecord
  ALLOWED_PROVIDERS = %w[local ollama mistral openai-compatible].freeze

  belongs_to :host

  validates :content,    presence: true
  validates :provider,   presence: true, inclusion: { in: ALLOWED_PROVIDERS }
  validates :model,      presence: true, length: { maximum: 128 }
  validates :dim,        presence: true,
                         numericality: { only_integer: true, greater_than: 0,
                                         less_than_or_equal_to: 4096 }
end
