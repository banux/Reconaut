# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Posture TLS de l'endpoint MCP — refus des connexions amont en clair
# si la posture l'exige.
#
# Cf. openspec/changes/init-reconaut-platform/tasks.md §5.5 :
#   "mcp.tls.required=true (défaut) refuse les connexions en clair.
#    mcp.tls.required=false (déploiement strictement interne avec mTLS
#    au reverse proxy) accepte les connexions amont en clair ; le boot
#    logue cette posture."
#
# Réglage via `RECONAUT_MCP_TLS_REQUIRED` :
#   - vide / non-défini / "true" / "1" / "yes" → required (défaut sécurisé)
#   - "false" / "0" / "no"                       → posture interne (clair toléré)
#
# Quand la posture est `required`, toute requête HTTP en clair est
# refusée 426 `tls-required`. La détection se fait via :
#   - `request.ssl?` (Rails) : true si le scheme est https.
#   - le header `X-Forwarded-Proto: https` (placé par un reverse proxy
#     qui terminate TLS amont — Rails l'honore quand `config.force_ssl`
#     ou `trusted_proxies` est configuré ; on le re-vérifie ici en
#     défense pour ne pas dépendre de la config Rails globale).
module McpTlsPosture
  extend ActiveSupport::Concern

  included do
    before_action :enforce_mcp_tls_posture!
  end

  private

  def enforce_mcp_tls_posture!
    return if Mcp::TlsPosture.allowed_in_clear?

    return if request.ssl?
    return if request.headers["X-Forwarded-Proto"].to_s.downcase == "https"

    head :upgrade_required, "X-Reconaut-Reason" => "tls-required"
  end
end
