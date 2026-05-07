# frozen_string_literal: true

require_relative "storage"
require_relative "password_hasher"
require_relative "authenticator"

module Reconaut
  module Auth
    # Bootstrap : cree le compte owner initial d'une instance fraichement
    # deployee. Idempotent : si AU MOINS UN user existe deja, refuse.
    # Retourne { user, api_key } avec le raw token visible UNE SEULE FOIS.
    #
    # Cf. openspec/changes/init-reconaut-platform/tasks.md section 7.2 :
    # "bootstrap d'une instance sans config OIDC, creation d'un compte
    # owner local, generation de cle API".
    #
    # Le bootstrap est volontairement minimal (pas de SMTP, pas de page
    # d'invitation, pas de mot de passe genere) : l'operateur fournit
    # email + password via env / stdin, et l'instance imprime le raw
    # token.
    module Bootstrap
      class AlreadyInitializedError < StandardError; end
      class MissingCredentialsError < StandardError; end

      module_function

      def call(email:, password:, registry: Reconaut::Registry.default)
        if email.to_s.strip.empty? || password.to_s.empty?
          raise MissingCredentialsError, "email and password required"
        end

        # Au plus un appel reussi par instance.
        if registry.user_store.list.any?
          raise AlreadyInitializedError,
                "instance already initialized (#{registry.user_store.list.size} user(s) present)"
        end

        hasher = registry.password_hasher
        user = registry.user_store.create(
          email: email,
          password_hash: hasher.hash(password),
          role: :owner
        )
        issued = registry.authenticator.issue_api_key(user_id: user.id)

        { user: user, api_key: issued }
      end
    end
  end
end
