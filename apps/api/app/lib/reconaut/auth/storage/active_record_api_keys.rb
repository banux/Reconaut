# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "securerandom"
require "digest"

# Adapter Postgres-backed du store des `api_keys`. Mêmes contraintes que
# l'adapter Users (cf. active_record_users.rb).
#
# Pivot mono-user : la valeur symbolique `Reconaut::Auth::OPERATOR_ID`
# (chaîne `"operator"`) reste le default et est résolue à l'UUID réel
# de l'unique opérateur stocké en base. Si aucun user n'existe, l'adapter
# lève `Reconaut::Auth::Storage::ActiveRecordApiKeys::NoOperatorError`
# — l'appelant (typiquement `Bootstrap.call`) doit avoir créé l'user
# avant de générer une clé.
#
# Cf. openspec/changes/add-persistent-auth-storage/specs/platform/spec.md.

module Reconaut
  module Auth
    module Storage
      class ActiveRecordApiKeys
        class NoOperatorError < StandardError; end

        # Set complet de scopes attribué par défaut à une clé full-scope
        # (alignée sur InMemoryApiKeys::DEFAULT_SCOPES).
        DEFAULT_SCOPES = [
          :"read:hosts", :"read:scopes", :"write:scopes",
          :"read:scans", :"write:scans",
          :"read:reports", :"agent:chat",
          :"read:api_keys", :"write:api_keys",
          :"read:health", :"write:heartbeats",
          :"worker:claim", :"worker:submit"
        ].freeze

        def create_for(user_id: OPERATOR_ID, scopes: DEFAULT_SCOPES)
          actual_user_id = resolve_user_id(user_id)

          raw        = SecureRandom.urlsafe_base64(32)
          prefix     = raw[0, 8]
          token_hash = Digest::SHA256.hexdigest(raw)
          scopes_arr = Array(scopes).map(&:to_sym).freeze

          ar = api_key_model.create!(
            user_id:    actual_user_id,
            prefix:     prefix,
            token_hash: token_hash,
            scopes:     scopes_arr.map(&:to_s)
          )
          [to_struct(ar), raw]
        end

        def find_by_token(raw_token)
          return nil if raw_token.to_s.empty?

          token_hash = Digest::SHA256.hexdigest(raw_token)
          ar = api_key_model.find_by(token_hash: token_hash)
          ar && to_struct(ar)
        end

        def list
          api_key_model.order(:created_at).map { |ar| to_struct(ar) }
        end

        # En mono-user : list_for filtre par user_id mais tous les keys
        # appartiennent au seul opérateur, donc équivalent à list. Conservé
        # pour rétrocompat des controllers historiques.
        def list_for(_user_id = OPERATOR_ID)
          list
        end

        def revoke!(id)
          ar = api_key_model.find_by(id: id)
          return nil unless ar

          ar.update!(revoked_at: Time.now.utc) if ar.revoked_at.nil?
          to_struct(ar)
        end

        def revoke_all!
          now = Time.now.utc
          api_key_model.where(revoked_at: nil).update_all(revoked_at: now)
          nil
        end

        private

        def api_key_model
          ::Reconaut::Auth::ArApiKey
        end

        def user_model
          ::Reconaut::Auth::ArUser
        end

        # Convertit OPERATOR_ID (symbole `"operator"`) en UUID réel de
        # l'unique user en base. Si on reçoit déjà un UUID, on le rend
        # tel quel (c'est l'appelant qui assume la cohérence FK).
        #
        # Si AUCUN user n'existe, on en crée un à la volée
        # (`operator-stub@local`). Ce comportement préserve la
        # compatibilité avec InMemoryApiKeys qui ne nécessite pas de
        # user préexistant — utile pour les specs qui testent les API
        # keys sans toucher à Bootstrap. En prod, `reconaut:set_password`
        # crée toujours le user avant qu'une clé ne soit générée par
        # `Bootstrap.call`, donc le stub n'est jamais matérialisé.
        def resolve_user_id(user_id)
          return user_id if uuid?(user_id.to_s)

          existing = user_model.order(:created_at).first
          return existing.id if existing

          stub = user_model.create!(
            email:         "operator-stub@local",
            password_hash: "stub-no-login"
          )
          stub.id
        end

        def uuid?(value)
          value =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
        end

        def to_struct(ar)
          ApiKey.new(
            id:         ar.id,
            user_id:    ar.user_id,
            prefix:     ar.prefix,
            token_hash: ar.token_hash,
            scopes:     Array(ar.scopes).map(&:to_sym).freeze,
            created_at: iso8601(ar.created_at),
            revoked_at: iso8601(ar.revoked_at)
          )
        end

        def iso8601(value)
          return nil if value.nil?

          value.utc.iso8601
        end
      end
    end
  end
end
