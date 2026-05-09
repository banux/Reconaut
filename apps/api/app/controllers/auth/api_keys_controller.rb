# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

module Auth
  # POST   /auth/api_keys           : crée une clé API personnelle pour
  #                                   l'opérateur unique. Renvoie le raw
  #                                   token UNE SEULE FOIS. Accepte un
  #                                   set `scopes:` optionnel ; à défaut
  #                                   la clé reçoit le set complet
  #                                   (DEFAULT_SCOPES).
  # GET    /auth/api_keys           : liste les clés (sans token).
  # DELETE /auth/api_keys/:id       : révoque une clé.
  #
  # Accès restreint au porteur d'une identité valide (auth via Bearer).
  # Le concern IdentityResolver fournit `current_identity` (cf. mono-user,
  # openspec/changes/single-user-only/).
  class ApiKeysController < ApplicationController
    include IdentityResolver

    before_action :require_authenticated!

    def index
      keys = Reconaut::Registry.default.api_key_store.list
      render json: { api_keys: keys.map(&:to_h) }
    end

    def create
      requested_scopes = Array(params[:scopes]).compact.map(&:to_s)
      issued = Reconaut::Registry.default.authenticator.issue_api_key(
        scopes: requested_scopes.empty? ? nil : requested_scopes
      )
      render status: :created, json: { api_key: issued }
    end

    def destroy
      store = Reconaut::Registry.default.api_key_store
      key = store.list.find { |k| k.id == params[:id] }
      return head :not_found unless key

      store.revoke!(key.id)
      head :no_content
    end

    private

    def require_authenticated!
      return if current_identity

      render status: :unauthorized, json: { error: "auth_required" }
    end
  end
end
