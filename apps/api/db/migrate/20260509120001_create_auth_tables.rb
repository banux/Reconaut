# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Tables `users` et `api_keys` persistantes.
#
# Cf. openspec/changes/add-persistent-auth-storage/specs/platform/spec.md
#   -> Requirement: Authentication (Single Operator) — Persistance
#
# Avant ce change, les users/api_keys vivaient en mémoire process-local
# (Reconaut::Auth::Storage::InMemory*). Conséquence : `rails reconaut:set_password`
# (un process) inscrit un opérateur invisible pour le serveur Rails
# (autre process) → 401 invalid_credentials sur `POST /auth/sessions`.
#
# Cette migration pose les tables AR-backées. Le mode mono-user reste
# garanti applicativement par `Reconaut::Auth::Bootstrap` (qui refuse
# si `users.count > 0` sauf rotate). Pas de check constraint `count <= 1`
# côté Postgres (couplage rigide).
class CreateAuthTables < ActiveRecord::Migration[8.1]
  def up
    enable_extension "citext"

    # ---- users --------------------------------------------------------------
    # Une instance = un seul opérateur (cf. single-user-only). On
    # n'ajoute pas de check constraint Postgres pour figer count <= 1 ;
    # la garde reste applicative dans Bootstrap.call.
    #
    # `email` est en `citext` pour rendre l'unicité naturellement
    # case-insensitive sans imposer un downcase manuel à chaque
    # comparaison.
    create_table :users, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.column :email,         :citext, null: false
      t.string :password_hash, null: false
      t.timestamp :created_at, null: false, default: -> { "now()" }
      t.timestamp :disabled_at
    end
    add_index :users, :email, unique: true, name: "idx_users_email_unique"

    # ---- api_keys -----------------------------------------------------------
    # Toutes les clés appartiennent à l'unique opérateur (mono-user). Le
    # `user_id` reste pour la forme du Struct historique mais n'est
    # jamais utilisé comme discriminant. ON DELETE CASCADE : si l'unique
    # user est supprimé (rare, dev), ses clés disparaissent avec lui.
    #
    # `token_hash` = SHA-256 hex du token brut (jamais persisté en clair).
    # `prefix` (8 chars) sert à identifier la clé dans les logs sans la
    # divulguer.
    create_table :api_keys, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false,
                          foreign_key: { on_delete: :cascade },
                          index: { name: "idx_api_keys_user_id" }
      t.string  :prefix,     null: false, limit: 8
      t.string  :token_hash, null: false, limit: 64
      t.column  :scopes,     "text[]", null: false, default: "{}"
      t.timestamp :created_at, null: false, default: -> { "now()" }
      t.timestamp :revoked_at
    end
    add_index :api_keys, :token_hash, unique: true, name: "idx_api_keys_token_hash_unique"
  end

  def down
    drop_table :api_keys
    drop_table :users
    # Note : on ne désactive pas l'extension citext (peut être utilisée
    # par d'autres tables ajoutées par la suite).
  end
end
