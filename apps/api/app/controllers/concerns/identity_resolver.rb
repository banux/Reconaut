# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# IdentityResolver : resoud l'identite de l'opérateur unique a partir
# du header `Authorization: Bearer <api_key>`. Aucune notion de role
# (cf. mode mono-user, openspec/changes/single-user-only/) — la
# politique d'acces vit dans les scopes attaches a la cle API courante,
# qui sont consommes par le tool MCP via `Mcp::Tool#call`.
#
# Cf. openspec/changes/single-user-only/specs/platform/spec.md
# (Requirement: Authentication (Single Operator)).
module IdentityResolver
  extend ActiveSupport::Concern

  def current_identity
    @current_identity ||= authenticator&.from_authorization(request.headers["Authorization"])
  end

  # Identifiant tracable pour le journal d'audit. En mode mono-user, on
  # privilegie le `key:<prefix>` de la cle API courante (defense en
  # profondeur : on identifie la cle precise utilisee, pas l'operateur
  # qui n'a qu'une seule identite implicite).
  def caller_id
    identity = current_identity
    identity ? identity.caller_id : "anonymous"
  end

  # Liste des scopes portes par la cle API courante. Vide quand aucun
  # `Authorization: Bearer` valide n'est presente.
  def caller_scopes
    identity = current_identity
    return [] unless identity&.api_key

    Array(identity.api_key.scopes).map(&:to_sym)
  end

  private

  def authenticator
    Reconaut::Registry.default.authenticator
  end
end
