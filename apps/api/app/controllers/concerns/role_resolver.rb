# frozen_string_literal: true

# Concern partage par tous les controllers REST. Dirige le RBAC vers les
# use cases sans coupler le code metier au framework Rails.
#
# Source temporaire : header X-Reconaut-Role posé par un middleware
# d'auth (a livrer plus tard avec init-reconaut-platform section 7.2 -
# auth local-first + OIDC). Pour l'instant on lit le header tel quel ;
# par defaut, role = :viewer (lecteur) pour ne JAMAIS accorder de droit
# eleve par defaut.
module RoleResolver
  extend ActiveSupport::Concern

  ROLES = %i[viewer analyst admin owner].freeze

  def caller_role
    raw = request.headers["X-Reconaut-Role"].to_s.downcase.to_sym
    ROLES.include?(raw) ? raw : :viewer
  end

  def caller_id
    request.headers["X-Reconaut-Caller"].presence || "anonymous"
  end
end
