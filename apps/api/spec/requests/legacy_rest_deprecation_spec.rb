# frozen_string_literal: true

require "rails_helper"

# Vérifie que tous les controllers REST hérités (hors allowlist mcp-first)
# portent une annotation DEPRECATED dans leur en-tête. Cf.
# openspec/changes/mcp-as-primary-entrypoint/tasks.md §2.4.
#
# Allowlist (cf. scripts/check_rest_allowlist.sh) : Auth::SessionsController,
# Auth::ApiKeysController, HealthController, Mcp::ToolsController,
# ApplicationController. Tout autre controller doit s'auto-déclarer
# deprecated tant qu'il n'est pas porté en outil MCP.
RSpec.describe "Legacy REST controllers carry DEPRECATED annotation" do
  ALLOWLIST = %w[
    application_controller.rb
    health_controller.rb
    auth/sessions_controller.rb
    auth/api_keys_controller.rb
    mcp/tools_controller.rb
  ].freeze

  controllers_dir = Rails.root.join("app/controllers")

  it "tous les controllers hors allowlist portent DEPRECATED" do
    all_controllers = Dir[controllers_dir.join("**/*.rb")]
                        .reject { |p| p.include?("/concerns/") }
                        .map { |p| Pathname.new(p).relative_path_from(controllers_dir).to_s }

    legacy = all_controllers - ALLOWLIST
    missing = legacy.reject do |rel|
      content = File.read(controllers_dir.join(rel))
      content.include?("DEPRECATED")
    end

    expect(missing).to be_empty,
      "Ces controllers REST hérités n'ont pas le marqueur DEPRECATED : #{missing.join(", ")}"
  end
end
