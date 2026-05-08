# frozen_string_literal: true

require "rails_helper"

# Vérifie que la matrice OPERATOR_SCOPES couvre toutes les scopes
# requises par les outils du registry. C'est un contrat structurel :
# si un nouvel outil MCP introduit un scope qui n'est pas dans
# OPERATOR_SCOPES, l'opérateur unique ne pourrait pas l'invoquer.
RSpec.describe Mcp::ToolsController do
  let(:registry) { Reconaut::Registry.default }

  before do
    Mcp::ToolRegistry.reset!
    response = Agent::HybridRetriever::Response.new(
      rows: [], citations: [], warnings: [],
      retrieval_path: "none", duration_ms: 0
    )
    retriever = Class.new {
      def initialize(r) = (@r = r)
      def call(_) = @r
    }.new(response)

    Mcp::CoreTools.register_all!(
      retriever:          retriever,
      scope_storage:      registry.scope_storage,
      scan_enqueuer:      registry.scan_enqueuer,
      api_key_storage:    registry.api_key_store,
      heartbeat_store:    registry.heartbeat_store
    )
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  it "OPERATOR_SCOPES couvre tous les scopes requis par les outils enregistrés" do
    required = Mcp::ToolRegistry.all.flat_map(&:scopes).uniq
    operator = described_class::OPERATOR_SCOPES
    missing  = required - operator
    expect(missing).to be_empty,
                       "OPERATOR_SCOPES manque : #{missing.inspect}. " \
                       "Ajouter ces scopes à #{described_class}::OPERATOR_SCOPES."
  end

  it "OPERATOR_SCOPES inclut write:heartbeats (cf. submit_heartbeat tool)" do
    expect(described_class::OPERATOR_SCOPES).to include(:"write:heartbeats")
  end

  it "SCOPES_BY_ROLE[:operator] est égal à OPERATOR_SCOPES" do
    expect(described_class::SCOPES_BY_ROLE[:operator]).to eq(described_class::OPERATOR_SCOPES)
  end
end
