# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "securerandom"
require "digest"
require "time"

module Reconaut
  module Auth
    # User : compte applicatif local. Persiste un email, un hash de
    # password (Argon2id). AUCUN mot de passe en clair n'est jamais
    # stocke.
    #
    # En mode mono-user (cf. openspec/changes/single-user-only/), le
    # champ `role` a ete retire — il y a un seul operateur par
    # instance, identifie implicitement.
    User = Struct.new(:id, :email, :password_hash, :created_at, :disabled_at,
                      keyword_init: true) do
      def disabled?
        !disabled_at.nil?
      end

      # to_h pour serialisation API : on n'expose JAMAIS le password_hash.
      def to_h
        {
          id: id, email: email,
          created_at: created_at, disabled_at: disabled_at
        }
      end
    end

    # En mode mono-user (cf. openspec/changes/single-user-only/), il n'y
    # a qu'un seul opérateur ; toutes les clés API lui appartiennent.
    # `OPERATOR_ID` est la valeur figée stockée dans `ApiKey.user_id`
    # pour conserver la forme du Struct sans introduire de table users
    # à plusieurs entrées.
    OPERATOR_ID = "operator"

    # ApiKey : clé API personnelle de l'opérateur unique. Stocke le
    # SHA-256 du token (jamais la valeur en clair) + un préfixe court
    # pour identifier la clé dans les logs sans la divulguer + son set
    # de scopes MCP (défense-en-profondeur : une clé scopée
    # `read:hosts` ne peut pas appeler un tool qui exige `write:scans`).
    ApiKey = Struct.new(:id, :user_id, :prefix, :token_hash, :scopes,
                        :created_at, :revoked_at, keyword_init: true) do
      def revoked?
        !revoked_at.nil?
      end

      def to_h
        {
          id: id, user_id: user_id, prefix: prefix,
          scopes: Array(scopes).map(&:to_s),
          created_at: created_at, revoked_at: revoked_at
        }
      end
    end

    # Stockage en memoire (tests + dev local). DB-backed via ActiveRecord
    # quand le modele User sera cree par init-reconaut-platform.
    module Storage
      class InMemoryUsers
        def initialize
          @users  = {}
          @by_email = {}
          @mutex  = Mutex.new
        end

        # En mode mono-user, `role:` est accepte par tolerance pour les
        # appelants existants mais ignore (le User n'a plus de role).
        # Cf. openspec/changes/single-user-only/.
        def create(email:, password_hash:, role: nil)
          _ = role # ignore
          email = email.to_s.downcase.strip
          raise ArgumentError, "invalid_email" if email.empty? || !email.include?("@")

          @mutex.synchronize do
            raise ArgumentError, "email_taken" if @by_email.key?(email)

            user = User.new(
              id:            SecureRandom.uuid,
              email:         email,
              password_hash: password_hash,
              created_at:    Time.now.utc.iso8601,
              disabled_at:   nil
            )
            @users[user.id]    = user
            @by_email[user.email] = user
            user
          end
        end

        def find_by_email(email)
          @mutex.synchronize { @by_email[email.to_s.downcase.strip] }
        end

        def find(id)
          @mutex.synchronize { @users[id] }
        end

        def list
          @mutex.synchronize { @users.values.map(&:dup) }
        end

        # Met à jour le password_hash d'un user existant (utilisé par
        # `Bootstrap.call(rotate: true)`). Renvoie le user mis à jour
        # ou nil si l'id est inconnu.
        def set_password_hash!(id, password_hash)
          @mutex.synchronize do
            user = @users[id]
            return nil unless user

            updated = User.new(
              id:            user.id,
              email:         user.email,
              password_hash: password_hash,
              created_at:    user.created_at,
              disabled_at:   user.disabled_at
            )
            @users[id] = updated
            @by_email[updated.email] = updated
            updated
          end
        end

        def disable!(id)
          @mutex.synchronize do
            user = @users[id]
            return nil unless user

            # User est immuable (Struct.new keyword_init), on reconstruit
            # un User avec disabled_at pose au lieu de muter.
            disabled = User.new(
              id:            user.id,
              email:         user.email,
              password_hash: user.password_hash,
              created_at:    user.created_at,
              disabled_at:   Time.now.utc.iso8601
            )
            @users[id] = disabled
            @by_email[disabled.email] = disabled
            disabled
          end
        end
      end

      class InMemoryApiKeys
        # Set complet de scopes attribué par défaut à une clé full-scope
        # (celle générée par `reconautctl login`). L'opérateur peut
        # générer des clés à scope réduit en passant `scopes:` à
        # `create_for` ; sinon c'est ce set qui s'applique.
        DEFAULT_SCOPES = [
          :"read:hosts", :"read:scopes", :"write:scopes",
          :"read:scans", :"write:scans",
          :"read:reports", :"agent:chat",
          :"read:api_keys", :"write:api_keys",
          :"read:health", :"write:heartbeats"
        ].freeze

        def initialize
          @keys = {}
          @by_hash = {}
          @mutex = Mutex.new
        end

        # Retourne (api_key_record, raw_token). Le raw_token n'est PAS
        # stocké ; l'appelant doit le transmettre à l'utilisateur une
        # seule fois (à la création).
        #
        # En mode mono-user (cf. openspec/changes/single-user-only/), le
        # paramètre `user_id:` est figé à `OPERATOR_ID` — il est conservé
        # avec une valeur par défaut pour ne pas casser les appelants
        # historiques, mais sa valeur réelle n'est jamais utilisée comme
        # discriminant.
        def create_for(user_id: OPERATOR_ID, scopes: DEFAULT_SCOPES)
          raw = SecureRandom.urlsafe_base64(32)
          prefix = raw[0, 8]
          token_hash = Digest::SHA256.hexdigest(raw)

          record = ApiKey.new(
            id:         SecureRandom.uuid,
            user_id:    user_id,
            prefix:     prefix,
            token_hash: token_hash,
            scopes:     Array(scopes).map(&:to_sym).freeze,
            created_at: Time.now.utc.iso8601,
            revoked_at: nil
          )
          @mutex.synchronize do
            @keys[record.id] = record
            @by_hash[token_hash] = record
          end
          [record, raw]
        end

        def find_by_token(raw_token)
          return nil if raw_token.to_s.empty?

          token_hash = Digest::SHA256.hexdigest(raw_token)
          @mutex.synchronize { @by_hash[token_hash] }
        end

        # En mode mono-user, toutes les clés appartiennent au seul
        # opérateur — `list` renvoie l'ensemble. `list_for` est
        # conservé pour rétrocompat des controllers historiques mais
        # délègue à `list` (le filtre par user_id n'a plus de sens).
        def list
          @mutex.synchronize { @keys.values.map(&:dup) }
        end

        def list_for(_user_id = OPERATOR_ID)
          list
        end

        def revoke!(id)
          @mutex.synchronize do
            key = @keys[id]
            return nil unless key

            revoked = key.dup
            revoked.revoked_at = Time.now.utc.iso8601
            @keys[id] = revoked
            @by_hash[key.token_hash] = revoked
            revoked
          end
        end

        # Révoque toutes les clés non encore révoquées. Utilisé par la
        # rake task `reconaut:set_password --rotate` pour forcer la
        # réauthentification après rotation du mot de passe.
        def revoke_all!
          @mutex.synchronize do
            now = Time.now.utc.iso8601
            @keys.each_value do |key|
              next if key.revoked?

              revoked = key.dup
              revoked.revoked_at = now
              @keys[key.id] = revoked
              @by_hash[key.token_hash] = revoked
            end
          end
        end
      end
    end
  end
end
