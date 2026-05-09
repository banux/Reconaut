# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "storage"
require_relative "password_hasher"
require_relative "authenticator"

module Reconaut
  module Auth
    # Bootstrap : pose le password de l'opérateur unique d'une instance.
    # En mode mono-user (cf. openspec/changes/single-user-only/), il n'y
    # a qu'un seul opérateur ; le bootstrap crée le compte la première
    # fois, ou roule le password sur demande explicite (`rotate: true`).
    #
    # Cf. openspec/changes/single-user-only/specs/platform/spec.md
    # (Scenario: Bootstrap initial pose le password de l'opérateur).
    module Bootstrap
      class AlreadyInitializedError < StandardError; end
      class MissingCredentialsError < StandardError; end

      module_function

      DEFAULT_OPERATOR_EMAIL = "operator@local"

      # Crée le compte opérateur initial avec son password Argon2id et
      # une première clé API. Idempotent : si un user existe déjà, lève
      # `AlreadyInitializedError` sauf si `rotate: true`. En mode rotation,
      # le password est mis à jour ET toutes les clés API existantes
      # sont révoquées (pour forcer la réauthentification).
      def call(email: DEFAULT_OPERATOR_EMAIL, password:, rotate: false, registry: Reconaut::Registry.default)
        if password.to_s.empty?
          raise MissingCredentialsError, "password required"
        end
        email = email.to_s.strip
        email = DEFAULT_OPERATOR_EMAIL if email.empty?

        existing = registry.user_store.list

        if existing.any? && !rotate
          raise AlreadyInitializedError,
                "instance already initialized (#{existing.size} user(s) present)"
        end

        hasher = registry.password_hasher

        user =
          if existing.any?
            # Rotation : on remplace le password du user existant et on
            # révoque toutes les clés API existantes (pour forcer la
            # réauthentification).
            registry.api_key_store.revoke_all!
            registry.user_store.set_password_hash!(existing.first.id, hasher.hash(password))
          else
            registry.user_store.create(
              email:         email,
              password_hash: hasher.hash(password)
            )
          end

        issued = registry.authenticator.issue_api_key(user_id: user.id)
        { user: user, api_key: issued, rotated: existing.any? && rotate }
      end
    end
  end
end
