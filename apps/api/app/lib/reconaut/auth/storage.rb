# frozen_string_literal: true

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

    # ApiKey : cle API personnelle attachee a un user. La table stocke
    # uniquement le SHA-256 du token (jamais la valeur en clair) +
    # un prefixe court pour identifier la cle dans les logs sans la
    # divulguer.
    ApiKey = Struct.new(:id, :user_id, :prefix, :token_hash,
                        :created_at, :revoked_at, keyword_init: true) do
      def revoked?
        !revoked_at.nil?
      end

      def to_h
        {
          id: id, user_id: user_id, prefix: prefix,
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
        def initialize
          @keys = {}
          @by_hash = {}
          @mutex = Mutex.new
        end

        # Retourne (api_key_record, raw_token). Le raw_token n'est PAS
        # stocke ; l'appelant doit le transmettre a l'utilisateur une
        # seule fois (a la creation).
        def create_for(user_id:)
          raw = SecureRandom.urlsafe_base64(32)
          prefix = raw[0, 8]
          token_hash = Digest::SHA256.hexdigest(raw)

          record = ApiKey.new(
            id:         SecureRandom.uuid,
            user_id:    user_id,
            prefix:     prefix,
            token_hash: token_hash,
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

        def list_for(user_id)
          @mutex.synchronize { @keys.values.select { |k| k.user_id == user_id }.map(&:dup) }
        end

        # En mode mono-user (single-user-only), le filtrage par user_id
        # n'a plus de sens — toutes les cles appartiennent au meme
        # operateur unique. `list` renvoie l'ensemble.
        def list
          @mutex.synchronize { @keys.values.map(&:dup) }
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
      end
    end
  end
end
