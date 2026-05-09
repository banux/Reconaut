# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Modèle ActiveRecord minimaliste mappant la table `api_keys`. Sert
# uniquement de couche de persistance pour l'adapter
# `Reconaut::Auth::Storage::ActiveRecordApiKeys`. La logique de scopes
# vit dans `Reconaut::Mcp::ScopeMap` ; ici on stocke juste un `text[]`.
#
# `token_hash` est un SHA-256 hex (jamais le token brut).
#
# Cf. openspec/changes/add-persistent-auth-storage/tasks.md §2.2.
module Reconaut
  module Auth
    class ArApiKey < ApplicationRecord
      self.table_name = "api_keys"

      belongs_to :ar_user,
                 class_name: "Reconaut::Auth::ArUser",
                 foreign_key: :user_id

      validates :prefix,     presence: true, length: { maximum: 8 }
      validates :token_hash, presence: true, length: { is: 64 }, uniqueness: true
    end
  end
end
