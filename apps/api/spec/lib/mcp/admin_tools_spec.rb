# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/mcp/core_tools"
require_relative "../../../app/lib/reconaut/auth/storage"
require_relative "../../../app/use_cases/scopes/storage"

# Specs des tools MCP api keys (list_api_keys, revoke_api_key) en mode
# mono-user. Cf. openspec/changes/single-user-only/specs/mcp-server/spec.md
# (REMOVED list_users / grant_role / revoke_role ; list_api_keys ne prend
# plus de parametre user_id).
RSpec.describe "Mcp::CoreTools api key tools" do
  let(:retriever) { instance_double(Agent::HybridRetriever) }
  let(:scope_storage) { Scopes::Storage::InMemory.new }
  let(:api_key_storage) { Reconaut::Auth::Storage::InMemoryApiKeys.new }

  before do
    Mcp::ToolRegistry.reset!
    Mcp::CoreTools.register_all!(
      retriever:       retriever,
      scope_storage:   scope_storage,
      api_key_storage: api_key_storage
    )
  end

  it "list_users n'est pas enregistré (mono-user)" do
    expect(Mcp::ToolRegistry.names).not_to include("list_users")
  end

  describe "list_api_keys" do
    let(:tool) { Mcp::ToolRegistry.fetch("list_api_keys") }

    it "expose le scope read:api_keys et zero paramètre" do
      expect(tool.scopes).to eq([:"read:api_keys"])
      expect(tool.params_schema).to eq({})
    end

    it "renvoie toutes les clés (mono-user, plus de filtre user_id)" do
      api_key_storage.create_for(user_id: "operator")
      api_key_storage.create_for(user_id: "operator")

      result = tool.call(
        params: {},
        caller_id: "operator",
        caller_scopes: [:"read:api_keys"]
      )
      expect(result[:api_keys].size).to eq(2)
      # to_h n'expose JAMAIS le token_hash (sensible)
      expect(result[:api_keys].first.keys).not_to include(:token_hash)
    end

    it "rejette l'appel sans le scope read:api_keys" do
      expect {
        tool.call(
          params: {},
          caller_id: "operator",
          caller_scopes: [:"read:hosts"]
        )
      }.to raise_error(Mcp::ScopeError, /read:api_keys/)
    end

    it "n'est pas enregistré si api_key_storage n'est pas injecté" do
      Mcp::ToolRegistry.reset!
      Mcp::CoreTools.register_all!(retriever: retriever, scope_storage: scope_storage)
      expect(Mcp::ToolRegistry.names).not_to include("list_api_keys")
    end
  end

  describe "revoke_api_key" do
    let(:tool) { Mcp::ToolRegistry.fetch("revoke_api_key") }

    it "expose le scope write:api_keys et un schema id" do
      expect(tool.scopes).to eq([:"write:api_keys"])
      expect(tool.params_schema.keys).to contain_exactly(:id)
    end

    it "happy path : révoque une clé existante" do
      record, _raw = api_key_storage.create_for(user_id: "operator")

      result = tool.call(
        params: { id: record.id },
        caller_id: "operator",
        caller_scopes: [:"write:api_keys"]
      )
      expect(result[:ok]).to be true
      expect(result[:api_key][:id]).to eq(record.id)
      expect(result[:api_key][:revoked_at]).not_to be_nil
    end

    it "renvoie api_key_not_found pour un id inconnu" do
      result = tool.call(
        params: { id: "00000000-0000-0000-0000-000000000000" },
        caller_id: "operator",
        caller_scopes: [:"write:api_keys"]
      )
      expect(result[:ok]).to be false
      expect(result[:error]).to eq("api_key_not_found")
    end

    it "rejette l'appel sans le scope write:api_keys" do
      expect {
        tool.call(
          params: { id: "x" },
          caller_id: "operator",
          caller_scopes: [:"read:api_keys"]
        )
      }.to raise_error(Mcp::ScopeError, /write:api_keys/)
    end
  end

  describe "round-trip list_api_keys / revoke_api_key" do
    it "list voit la clé, revoke, list voit revoked_at non-nul" do
      list_tool   = Mcp::ToolRegistry.fetch("list_api_keys")
      revoke_tool = Mcp::ToolRegistry.fetch("revoke_api_key")
      record, _raw = api_key_storage.create_for(user_id: "operator")

      before_revoke = list_tool.call(
        params: {},
        caller_id: "operator",
        caller_scopes: [:"read:api_keys"]
      )
      expect(before_revoke[:api_keys].first[:revoked_at]).to be_nil

      revoke_tool.call(
        params: { id: record.id },
        caller_id: "operator",
        caller_scopes: [:"write:api_keys"]
      )

      after_revoke = list_tool.call(
        params: {},
        caller_id: "operator",
        caller_scopes: [:"read:api_keys"]
      )
      expect(after_revoke[:api_keys].first[:revoked_at]).not_to be_nil
    end
  end
end
