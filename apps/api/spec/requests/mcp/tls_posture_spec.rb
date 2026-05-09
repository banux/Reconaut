# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/init-reconaut-platform/tasks.md §5.5 :
#   "Avec tls.required=true : tentative HTTP en clair refusée avec
#    raison `tls-required` ; HTTPS valide réussit. Avec
#    tls.required=false : tentative HTTP en clair acceptée et le log
#    de boot mentionne `mcp.tls.required=false posture=internal`."

RSpec.describe "MCP TLS posture", type: :request do
  let(:registry) { Reconaut::Registry.default }

  let(:retriever) do
    Class.new {
      def call(_q)
        Agent::HybridRetriever::Response.new(
          rows: [], citations: [], warnings: [], retrieval_path: "graph", duration_ms: 1
        )
      end
    }.new
  end

  before do
    Mcp::ToolRegistry.reset!
    Mcp::CoreTools.register_all!(
      retriever:     retriever,
      scope_storage: Scopes::Storage::InMemory.new,
      scan_enqueuer: registry.scan_enqueuer
    )
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  describe "posture required (défaut)" do
    around do |ex|
      original = ENV["RECONAUT_MCP_TLS_REQUIRED"]
      ENV.delete("RECONAUT_MCP_TLS_REQUIRED") # = défaut required
      ex.run
    ensure
      # Restauration explicite (même si original était nil) pour
      # ne pas laisser ENV vide → les specs suivantes héritent du
      # défaut sécurisé et planteraient.
      if original.nil?
        ENV["RECONAUT_MCP_TLS_REQUIRED"] = "false" # défaut rails_helper
      else
        ENV["RECONAUT_MCP_TLS_REQUIRED"] = original
      end
    end

    it "refuse une requête HTTP en clair avec 426 + reason tls-required" do
      post "/mcp/tools/list_scopes",
           params:  {}.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:upgrade_required) # 426
      expect(response.headers["X-Reconaut-Reason"]).to eq("tls-required")
    end

    it "accepte une requête avec X-Forwarded-Proto: https (TLS terminé en amont)" do
      post "/mcp/tools/list_scopes",
           params:  {}.to_json,
           headers: {
             "Content-Type"      => "application/json",
             "X-Forwarded-Proto" => "https"
           }

      # Le code applicatif tourne ; la réponse est 200 ou 401 (pas 426).
      expect(response.status).not_to eq(426)
    end
  end

  describe "posture internal (mcp.tls.required=false)" do
    around do |ex|
      original = ENV["RECONAUT_MCP_TLS_REQUIRED"]
      ENV["RECONAUT_MCP_TLS_REQUIRED"] = "false"
      ex.run
    ensure
      ENV["RECONAUT_MCP_TLS_REQUIRED"] = original
    end

    it "accepte une requête HTTP en clair sans 426" do
      post "/mcp/tools/list_scopes",
           params:  {}.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response.status).not_to eq(426)
    end
  end

  describe "Mcp::TlsPosture helper" do
    # Restaure systématiquement la valeur par défaut "false" posée par
    # rails_helper.rb pour ne pas casser les autres specs qui supposent
    # le clair toléré en environnement de test.
    around do |ex|
      original = ENV["RECONAUT_MCP_TLS_REQUIRED"]
      ex.run
    ensure
      ENV["RECONAUT_MCP_TLS_REQUIRED"] = original
    end

    it "défaut = required" do
      ENV.delete("RECONAUT_MCP_TLS_REQUIRED")
      expect(Mcp::TlsPosture.required?).to be true
      expect(Mcp::TlsPosture.allowed_in_clear?).to be false
    end

    it "false / 0 / no → not required" do
      %w[false 0 no FALSE No].each do |val|
        ENV["RECONAUT_MCP_TLS_REQUIRED"] = val
        expect(Mcp::TlsPosture.required?).to be(false), "got required? for #{val}"
      end
    end

    it "log_at_boot! émet un warn avec posture=internal quand non requis" do
      ENV["RECONAUT_MCP_TLS_REQUIRED"] = "false"
      logger = double("logger")
      expect(logger).to receive(:warn).with(/posture=internal/)
      Mcp::TlsPosture.log_at_boot!(logger)
    end

    it "log_at_boot! émet un info avec posture=internet-facing par défaut" do
      ENV.delete("RECONAUT_MCP_TLS_REQUIRED")
      logger = double("logger")
      expect(logger).to receive(:info).with(/posture=internet-facing/)
      Mcp::TlsPosture.log_at_boot!(logger)
    end
  end
end
