# frozen_string_literal: true

module Auth
  # POST /auth/sessions : authentifie via email + password contre le
  # store local. La v1 ne fixe pas de cookie : on renvoie le user et
  # une cle API issue par defaut a la session, que le frontend stocke
  # cote client. Une vraie session base sur cookie / token JWT viendra
  # quand on cablera ActiveRecord et qu'on aura un store de sessions.
  #
  # Cf. init-reconaut-platform section 7.2.
  class SessionsController < ApplicationController
    def create
      email    = params[:email].to_s
      password = params[:password].to_s

      auth = Reconaut::Registry.default.authenticator

      # Mode mono-user (cf. openspec/changes/single-user-only/§4.2) :
      # le body peut ne contenir que `password`. Si email est fourni
      # explicitement, on garde le chemin email+password pour
      # rétrocompat (et pour les tests historiques).
      identity =
        if email.empty?
          auth.from_password_only(password: password)
        else
          auth.from_password(email: email, password: password)
        end

      if identity.nil?
        return render(status: :unauthorized, json: { error: "invalid_credentials" })
      end

      issued = auth.issue_api_key(user_id: identity.user.id)
      render status: :created, json: {
        user: identity.user.to_h,
        api_key: issued
      }
    end
  end
end
