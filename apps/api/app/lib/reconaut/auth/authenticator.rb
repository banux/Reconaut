# frozen_string_literal: true

require_relative "storage"
require_relative "password_hasher"

module Reconaut
  module Auth
    # Authentifie une requete entrante. Deux modes pris en charge :
    #
    # 1. Cle API personnelle (Bearer) : header `Authorization: Bearer <raw>`
    #    -> on hashe `<raw>` en SHA-256, on cherche la cle dans
    #    InMemoryApiKeys, on remonte au user. C'est la voie principale
    #    pour les agents externes (MCP).
    #
    # 2. Email + password : pour la creation d'une session UI
    #    (POST /auth/sessions).
    #
    # Les retours : `Identity(user, source: :api_key | :password)` ou nil.
    # Aucune branche du code n'expose le password ni le raw token au
    # journal d'audit ; seul le `user.id` est trace.
    #
    # Cf. openspec/changes/init-reconaut-platform/tasks.md section 7.2.
    Identity = Struct.new(:user, :api_key, :source, keyword_init: true) do
      def caller_id
        if source == :api_key && api_key
          "key:#{api_key.prefix}"
        else
          "user:#{user.id}"
        end
      end

      # En mode mono-user (cf. openspec/changes/single-user-only/),
      # tous les utilisateurs sont l'opérateur unique. La méthode
      # `role` est conservée pour compat des controllers hérités mais
      # renvoie toujours `:operator`.
      def role
        :operator
      end
    end

    class Authenticator
      def initialize(user_store:, api_key_store:, password_hasher: PasswordHasher.default)
        @users           = user_store
        @keys            = api_key_store
        @password_hasher = password_hasher
      end

      # Resolution depuis une requete HTTP. `auth_header` est la valeur
      # brute de `Authorization` (peut etre nil ou "Bearer <token>").
      # Retourne nil si aucune identite ne peut etre etablie.
      def from_authorization(auth_header)
        return nil if auth_header.to_s.empty?

        match = auth_header.to_s.match(/\ABearer\s+(.+)\z/i)
        return nil unless match

        raw = match[1].strip
        key = @keys.find_by_token(raw)
        return nil if key.nil? || key.revoked?

        user = @users.find(key.user_id)
        return nil if user.nil? || user.disabled?

        Identity.new(user: user, api_key: key, source: :api_key)
      end

      def from_password(email:, password:)
        user = @users.find_by_email(email)
        # Toujours executer un verify, meme sur user inexistant, pour ne
        # pas leaker l'existence du compte par timing.
        if user.nil?
          @password_hasher.verify(password, fake_hash)
          return nil
        end
        return nil if user.disabled?
        return nil unless @password_hasher.verify(password, user.password_hash)

        Identity.new(user: user, api_key: nil, source: :password)
      end

      def issue_api_key(user_id:)
        record, raw = @keys.create_for(user_id: user_id)
        { id: record.id, prefix: record.prefix, token: raw, created_at: record.created_at }
      end

      private

      # Hash d'un faux mot de passe garde en cache pour egaliser le cout
      # CPU des branches "user trouve" / "user inexistant".
      def fake_hash
        @fake_hash ||= @password_hasher.hash("__never_match__#{SecureRandom.hex}")
      end
    end
  end
end
