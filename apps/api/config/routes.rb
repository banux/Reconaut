Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Endpoints consommes par apps/web (cf. apps/web/src/api/).
  post "/agent/chat", to: "agent/chat#create"

  resources :scopes, only: %i[index create destroy]
end
