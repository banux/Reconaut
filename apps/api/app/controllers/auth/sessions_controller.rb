# frozen_string_literal: true

module Auth
  # POST /auth/sessions : authentifie via password local et émet une
  # nouvelle clé API personnelle. En mode mono-user (cf.
  # openspec/changes/single-user-only/), le body ne contient qu'un
  # `password` ; un éventuel `email` dans le body est silencieusement
  # ignoré (un seul opérateur par instance, pas de discriminant).
  class SessionsController < ApplicationController
    def create
      password = params[:password].to_s
      auth     = Reconaut::Registry.default.authenticator
      identity = auth.from_password_only(password: password)

      if identity.nil?
        return render(status: :unauthorized, json: { error: "invalid_credentials" })
      end

      issued = auth.issue_api_key(user_id: identity.user.id)
      render status: :created, json: {
        user:    identity.user.to_h,
        api_key: issued
      }
    end
  end
end
