# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Loggue la posture TLS au boot — visible dans les logs Rails au
# démarrage pour que l'opérateur valide d'un coup d'œil que la posture
# correspond à son intention de déploiement.
#
# Cf. openspec/changes/init-reconaut-platform/tasks.md §5.5.
Rails.application.config.after_initialize do
  Mcp::TlsPosture.log_at_boot!
rescue StandardError => e
  Rails.logger&.warn("[mcp.tls] log au boot impossible : #{e.class}: #{e.message}")
end
