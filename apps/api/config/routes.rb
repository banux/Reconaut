Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Healthcheck non authentifié, dédié aux probes (LB, k8s, prometheus
  # blackbox). Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
  # (Requirement: REST API Reduced to Bootstrap, Health and MCP Transport).
  get "/healthz", to: "health#show"

  # Endpoints consommes par apps/web (cf. apps/web/src/api/).
  post "/agent/chat", to: "agent/chat#create"

  resources :scopes, only: %i[index create destroy]

  # Auth local-first (cf. init-reconaut-platform section 7.2).
  scope "/auth" do
    post   "/sessions", to: "auth/sessions#create"
    get    "/api_keys", to: "auth/api_keys#index"
    post   "/api_keys", to: "auth/api_keys#create"
    delete "/api_keys/:id", to: "auth/api_keys#destroy"
  end

  # Server MCP integre au process Rails (cf. add-tech-stack section 4.1
  # et init-reconaut-platform section 5.1). Pas de processus separe.
  scope "/mcp" do
    get  "/tools",            to: "mcp/tools#list"
    post "/tools/:tool_name", to: "mcp/tools#invoke"
  end
end
