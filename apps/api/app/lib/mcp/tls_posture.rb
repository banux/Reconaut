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

    # Lecture stricte (case-insensitive). La valeur par défaut est
    # `required` — c'est la posture "internet-facing" sécurisée. Un
    # opérateur en déploiement strictement interne (mTLS au reverse
    # proxy) peut explicitement la désactiver.
    def required?
      raw = ENV["RECONAUT_MCP_TLS_REQUIRED"].to_s.downcase.strip
      !%w[false 0 no].include?(raw)
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
