# frozen_string_literal: true

require "rails_helper"

# Vérifie que le set OPERATOR_SCOPES couvre tous les scopes requis par
# les outils du registry. Contrat structurel : si un nouvel outil MCP
# introduit un scope absent du set par défaut d'une clé full-scope,
# l'opérateur unique ne pourrait pas l'invoquer.
#
# Cf. openspec/changes/single-user-only/specs/mcp-server/spec.md
# (la matrice ne fait plus référence à un rôle ; elle se réduit au
# set de scopes attaché à chaque clé API).
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
      retriever:        retriever,
      scope_storage:    registry.scope_storage,
      scan_enqueuer:    registry.scan_enqueuer,
      api_key_storage:  registry.api_key_store,
      heartbeat_store:  registry.heartbeat_store
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
                       "Ajouter ces scopes à InMemoryApiKeys::DEFAULT_SCOPES."
  end

  it "OPERATOR_SCOPES inclut write:heartbeats (cf. submit_heartbeat tool)" do
    expect(described_class::OPERATOR_SCOPES).to include(:"write:heartbeats")
  end

  it "OPERATOR_SCOPES est exactement le set DEFAULT_SCOPES de InMemoryApiKeys" do
    expect(described_class::OPERATOR_SCOPES)
      .to eq(Reconaut::Auth::Storage::InMemoryApiKeys::DEFAULT_SCOPES)
  end
end
