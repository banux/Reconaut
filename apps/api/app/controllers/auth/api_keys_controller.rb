# frozen_string_literal: true

module Auth
  # POST   /auth/api_keys             : cree une cle API pour l'identite
  #                                     authentifiee. Renvoie le raw token
  #                                     UNE SEULE FOIS.
  # GET    /auth/api_keys             : liste les cles (sans token).
  # DELETE /auth/api_keys/:id         : revoque une cle.
  #
  # Acces restreint au porteur d'une identite valide (auth via Bearer ou
  # session). Le concern RoleResolver fournit `current_identity`.
  class ApiKeysController < ApplicationController
    include RoleResolver

    before_action :require_authenticated!

    def index
      keys = Reconaut::Registry.default.api_key_store.list_for(current_identity.user.id)
      render json: { api_keys: keys.map(&:to_h) }
    end

    def create
      issued = Reconaut::Registry.default.authenticator
        .issue_api_key(user_id: current_identity.user.id)
      render status: :created, json: { api_key: issued }
    end

    def destroy
      store = Reconaut::Registry.default.api_key_store
      key = store.list_for(current_identity.user.id).find { |k| k.id == params[:id] }
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
