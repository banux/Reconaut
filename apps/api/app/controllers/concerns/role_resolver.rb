# frozen_string_literal: true

# Resoud l'identite d'une requete HTTP. Deux chemins :
#
# 1. Bearer token via Authorization: l'authenticator de la registry
#    cherche la cle, remonte au user, expose user.role et caller_id =
#    "key:<prefix>". C'est la voie principale pour les agents externes
#    (MCP) et le frontend post-login.
#
# 2. Headers X-Reconaut-Role / X-Reconaut-Caller : voie de test +
#    bootstrap. Ne sert que si AUCUN Authorization n'est presente. Cette
#    porte de devanture sera fermee en production via une variable d'env
#    `RECONAUT_ALLOW_HEADER_ROLE=false` (defaut sera `false` en prod ;
#    on la garde a `true` tant que le frontend ne pose pas encore de
#    Bearer reel - cf. § 7.2).
#
# Cf. openspec/changes/init-reconaut-platform/tasks.md section 7.2.
module RoleResolver
  extend ActiveSupport::Concern

  # Roles cf. init-reconaut-platform 7.3.
  #   - viewer     : lecture seule du dataset (pas /agent/chat).
  #   - analyst    : viewer + agent + lecture des resultats.
  #   - admin      : analyst + scope mutation + write:scans.
  #   - owner      : admin + tout.
  #   - mcp_client : profil agent externe (cle API service-to-service).
  #     Equivalent analyst sur les outils MCP de lecture + write:scans
  #     pour declencher des scans, mais PAS de droit sur la mutation
  #     du scope (reservee a admin/owner).
  ROLES = %i[viewer analyst admin owner mcp_client].freeze

  def caller_role
    @caller_role ||= resolve_role
  end

  def caller_id
    @caller_id ||= resolve_caller_id
  end

  def current_identity
    @current_identity ||= authenticator&.from_authorization(request.headers["Authorization"])
  end

  private

  def authenticator
    Reconaut::Registry.default.authenticator
  end

  def resolve_role
    identity = current_identity
    return identity.role if identity

    return :viewer unless allow_header_role?

    raw = request.headers["X-Reconaut-Role"].to_s.downcase.to_sym
    ROLES.include?(raw) ? raw : :viewer
  end

  def resolve_caller_id
    identity = current_identity
    return identity.caller_id if identity

    request.headers["X-Reconaut-Caller"].presence || "anonymous"
  end

  def allow_header_role?
    ENV.fetch("RECONAUT_ALLOW_HEADER_ROLE", "true") != "false"
  end
end
