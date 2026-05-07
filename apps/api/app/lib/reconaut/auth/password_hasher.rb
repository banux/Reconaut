# frozen_string_literal: true

require "argon2"

module Reconaut
  module Auth
    # Interface commune des hasheurs de mot de passe. La v1 livre une
    # implementation Argon2id (recommandee par OWASP). Le hash et la
    # verification sont resistants au timing-attack par construction
    # (la lib argon2 utilise un compare en temps constant).
    #
    # Cf. openspec/changes/init-reconaut-platform/tasks.md section 7.2
    # ("mots de passe Argon2id").
    module PasswordHasher
      class InvalidHashError < StandardError; end

      # Argon2id : profil "interactive" (t=2, m=16 -> 2^16 KiB = 64 MiB,
      # p=1). Aligne sur les recommandations Argon2 RFC9106 / OWASP 2024.
      # Le cost est volontairement bas pour rester < 100 ms en CI ;
      # ajustable via RECONAUT_ARGON2_T_COST / M_COST.
      class Argon2id
        DEFAULT_T_COST = 2
        DEFAULT_M_COST = 16

        def initialize(t_cost: DEFAULT_T_COST, m_cost: DEFAULT_M_COST)
          @hasher = ::Argon2::Password.new(t_cost: t_cost, m_cost: m_cost)
        end

        def hash(password)
          raise ArgumentError, "password required" if password.to_s.empty?

          @hasher.create(password)
        end

        def verify(password, hash_string)
          return false if password.to_s.empty? || hash_string.to_s.empty?

          # Le hash argon2 commence toujours par "$argon2". Filtrer les
          # entrees qui ne respectent pas ce prefixe pour distinguer
          # "mauvais format" de "mauvais mot de passe".
          unless hash_string.to_s.start_with?("$argon2")
            raise InvalidHashError, "stored hash is not a valid argon2 hash"
          end

          ::Argon2::Password.verify_password(password, hash_string)
        end
      end

      # Implementation utilisable en tests qui n'ont pas besoin du cout
      # CPU d'Argon2 (par ex. seed de fixtures). Un test qui veut
      # explicitement Argon2 instancie Argon2id directement.
      class Plain
        def hash(password)    = "plain:#{password}"
        def verify(password, hash_string)
          return false if hash_string.to_s.empty?

          hash_string == "plain:#{password}"
        end
      end

      module_function

      def default
        @default ||= Argon2id.new
      end
    end
  end
end
