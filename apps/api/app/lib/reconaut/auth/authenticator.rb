# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

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
      # En mode mono-user (cf. openspec/changes/single-user-only/), il
      # n'y a qu'un seul opérateur implicite. Le lookup user est un
      # service de confort (pour l'audit affichage), pas un gate
      # d'auth — la validation de la clé suffit. Si aucun user n'est
      # enregistré (instance fraîchement bootstrappée), on retourne
      # quand même une Identity avec un user "implicite" pour ne pas
      # casser les chemins audit.
      def from_authorization(auth_header)
        return nil if auth_header.to_s.empty?

        match = auth_header.to_s.match(/\ABearer\s+(.+)\z/i)
        return nil unless match

        raw = match[1].strip
        key = @keys.find_by_token(raw)
        return nil if key.nil? || key.revoked?

        user = @users.list.first || implicit_operator
        return nil if user.respond_to?(:disabled?) && user.disabled?

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

      # En mode mono-user (cf. openspec/changes/single-user-only/), il
      # n'y a qu'un seul user enregistré : on peut authentifier sur le
      # password seul. Si plusieurs users existent (instance non
      # bootstrappée correctement), on refuse pour éviter d'exposer une
      # ambiguité.
      def from_password_only(password:)
        users = @users.list
        if users.empty?
          @password_hasher.verify(password, fake_hash)
          return nil
        end
        if users.size > 1
          # Cas pathologique. On verifie quand meme un fake hash pour
          # rester equilibre cote timing puis on refuse.
          @password_hasher.verify(password, fake_hash)
          return nil
        end

        user = users.first
        return nil if user.disabled?
        return nil unless @password_hasher.verify(password, user.password_hash)

        Identity.new(user: user, api_key: nil, source: :password)
      end

      def issue_api_key(user_id: Reconaut::Auth::OPERATOR_ID, scopes: nil)
        kwargs = { user_id: user_id }
        kwargs[:scopes] = scopes if scopes
        record, raw = @keys.create_for(**kwargs)
        {
          id:         record.id,
          prefix:     record.prefix,
          scopes:     record.scopes.map(&:to_s),
          token:      raw,
          created_at: record.created_at
        }
      end

      private

      # Opérateur implicite : utilisé quand aucun User n'a encore été
      # créé en base mais que la clé est valide (cas pathologique mais
      # pas bloquant — l'audit retombe sur key:<prefix>).
      def implicit_operator
        @implicit_operator ||= User.new(
          id:            Reconaut::Auth::OPERATOR_ID,
          email:         "operator@local",
          password_hash: nil,
          created_at:    Time.now.utc.iso8601,
          disabled_at:   nil
        )
      end

      # Hash d'un faux mot de passe garde en cache pour egaliser le cout
      # CPU des branches "user trouve" / "user inexistant".
      def fake_hash
        @fake_hash ||= @password_hasher.hash("__never_match__#{SecureRandom.hex}")
      end
    end
  end
end
