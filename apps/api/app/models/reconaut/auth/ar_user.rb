# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Modèle ActiveRecord minimaliste mappant la table `users`. Sert
# uniquement de couche de persistance pour l'adapter
# `Reconaut::Auth::Storage::ActiveRecordUsers`. Toute la logique métier
# (hashing, validation password, mode mono-user) reste dans
# `Reconaut::Auth::Authenticator` / `Reconaut::Auth::Bootstrap`.
#
# Le préfixe `AR*` évite la collision avec le `Struct User` historique
# défini dans `Reconaut::Auth::Storage` qui reste le contrat public.
#
# Cf. openspec/changes/add-persistent-auth-storage/tasks.md §2.1.
module Reconaut
  module Auth
    class ArUser < ApplicationRecord
      self.table_name = "users"

      has_many :ar_api_keys,
               class_name: "Reconaut::Auth::ArApiKey",
               foreign_key: :user_id,
               dependent: :destroy

      validates :email, presence: true, length: { maximum: 320 }
      validates :password_hash, presence: true
    end
  end
end
