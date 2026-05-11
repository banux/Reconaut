# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Mcp::TlsPosture : lit la variable d'environnement
# `RECONAUT_MCP_TLS_REQUIRED` et expose deux helpers :
#
#   - Mcp::TlsPosture.required?       — true si le clair est interdit
#   - Mcp::TlsPosture.allowed_in_clear? — convenience inverse
#
# Cf. openspec/changes/init-reconaut-platform/tasks.md §5.5.
module Mcp
  module TlsPosture
    module_function

    # Lecture stricte (case-insensitive) avec défaut par environnement :
    #
    #   - production / staging         → required (défaut sécurisé)
    #   - development / test           → non required (friction zéro sur
    #                                     `rails server` localhost)
    #
    # L'opérateur peut TOUJOURS surcharger via `RECONAUT_MCP_TLS_REQUIRED`
    # (`true`/`false`/`1`/`0`/`yes`/`no`, case-insensitive). Quand l'env
    # var n'est pas définie, le défaut suit l'environnement Rails.
    def required?
      raw = ENV["RECONAUT_MCP_TLS_REQUIRED"].to_s.downcase.strip
      return !%w[false 0 no].include?(raw) unless raw.empty?

      # Pas d'env var explicite : on suit le défaut par Rails.env.
      !permissive_env?
    end

    # permissive_env? : true en development/test, false ailleurs.
    # Le fallback `true` quand Rails n'est pas chargé (cas exotique des
    # specs unitaires hors Rails) garde le comportement permissif.
    def permissive_env?
      return true unless defined?(::Rails) && ::Rails.respond_to?(:env)

      env = ::Rails.env
      env.development? || env.test?
    end

    def allowed_in_clear?
      !required?
    end

    # Loggue la posture au boot. Appelé par l'initializer.
    def log_at_boot!(logger = Rails.logger)
      if required?
        logger.info("[mcp.tls] mcp.tls.required=true posture=internet-facing")
      else
        logger.warn(
          "[mcp.tls] mcp.tls.required=false posture=internal " \
          "(clair toléré ; assurez-vous que mTLS termine au reverse proxy)"
        )
      end
    end
  end
end
