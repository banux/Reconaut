# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/mcp/core_tools"
require_relative "../../../app/lib/reconaut/auth/storage"
require_relative "../../../app/use_cases/scopes/storage"

# Specs des tools MCP admin (list_users, list_api_keys, revoke_api_key)
# ajoutes par openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md.
RSpec.describe "Mcp::CoreTools admin tools" do
  let(:retriever) { instance_double(Agent::HybridRetriever) }
  let(:scope_storage) { Scopes::Storage::InMemory.new }
  let(:user_storage) { Reconaut::Auth::Storage::InMemoryUsers.new }
  let(:api_key_storage) { Reconaut::Auth::Storage::InMemoryApiKeys.new }

  before do
    Mcp::ToolRegistry.reset!
    Mcp::CoreTools.register_all!(
      retriever:       retriever,
      scope_storage:   scope_storage,
      user_storage:    user_storage,
      api_key_storage: api_key_storage
    )
  end

  describe "list_users" do
    let(:tool) { Mcp::ToolRegistry.fetch("list_users") }

    it "expose le scope read:users et zero parametre" do
      expect(tool.scopes).to eq([:"read:users"])
      expect(tool.params_schema).to eq({})
    end

    it "renvoie la liste des utilisateurs avec to_h (sans password_hash)" do
      user_storage.create(email: "owner@example.test", password_hash: "h1", role: :owner)
      user_storage.create(email: "ana@example.test",   password_hash: "h2", role: :analyst)

      result = tool.call(
        params: {},
        caller_id: "u-1",
        caller_scopes: [:"read:users"]
      )
      expect(result[:users].size).to eq(2)
      emails = result[:users].map { |u| u[:email] }
      expect(emails).to contain_exactly("owner@example.test", "ana@example.test")
      expect(result[:users].first.keys).not_to include(:password_hash)
    end

    it "rejette l'appel sans le scope read:users" do
      expect {
        tool.call(
          params: {},
          caller_id: "u-1",
          caller_scopes: [:"read:hosts"]
        )
      }.to raise_error(Mcp::ScopeError, /read:users/)
    end

    it "n'est pas enregistre si user_storage n'est pas injecte" do
      Mcp::ToolRegistry.reset!
      Mcp::CoreTools.register_all!(retriever: retriever, scope_storage: scope_storage)
      expect(Mcp::ToolRegistry.names).not_to include("list_users")
    end
  end

  describe "list_api_keys" do
    let(:tool) { Mcp::ToolRegistry.fetch("list_api_keys") }

    it "expose le scope read:api_keys et un parametre user_id optionnel" do
      expect(tool.scopes).to eq([:"read:api_keys"])
      expect(tool.params_schema.keys).to contain_exactly(:user_id)
      expect(tool.params_schema[:user_id][:required]).to be false
    end

    it "renvoie les cles d'un user explicitement designe" do
      user = user_storage.create(email: "a@example.test", password_hash: "h", role: :admin)
      api_key_storage.create_for(user_id: user.id)
      api_key_storage.create_for(user_id: user.id)
      api_key_storage.create_for(user_id: "other-user")

      result = tool.call(
        params: { user_id: user.id },
        caller_id: "caller-id",
        caller_scopes: [:"read:api_keys"]
      )
      expect(result[:user_id]).to eq(user.id)
      expect(result[:api_keys].size).to eq(2)
      # to_h n'expose JAMAIS le token_hash (sensible) ni de raw token.
      expect(result[:api_keys].first.keys).not_to include(:token_hash)
    end

    it "sans user_id : restreint aux cles du caller (defense par defaut)" do
      _, _ = api_key_storage.create_for(user_id: "caller-id")
      _, _ = api_key_storage.create_for(user_id: "other")

      result = tool.call(
        params: {},
        caller_id: "caller-id",
        caller_scopes: [:"read:api_keys"]
      )
      expect(result[:user_id]).to eq("caller-id")
      expect(result[:api_keys].size).to eq(1)
      expect(result[:api_keys].first[:user_id]).to eq("caller-id")
    end

    it "rejette l'appel sans le scope read:api_keys" do
      expect {
        tool.call(
          params: {},
          caller_id: "u-1",
          caller_scopes: [:"read:users"]
        )
      }.to raise_error(Mcp::ScopeError, /read:api_keys/)
    end
  end

  describe "revoke_api_key" do
    let(:tool) { Mcp::ToolRegistry.fetch("revoke_api_key") }

    it "expose le scope write:api_keys et un schema id" do
      expect(tool.scopes).to eq([:"write:api_keys"])
      expect(tool.params_schema.keys).to contain_exactly(:id)
    end

    it "happy path : revoque une cle existante" do
      record, _raw = api_key_storage.create_for(user_id: "u-1")

      result = tool.call(
        params: { id: record.id },
        caller_id: "u-1",
        caller_scopes: [:"write:api_keys"]
      )
      expect(result[:ok]).to be true
      expect(result[:api_key][:id]).to eq(record.id)
      expect(result[:api_key][:revoked_at]).not_to be_nil
    end

    it "renvoie api_key_not_found pour un id inconnu" do
      result = tool.call(
        params: { id: "00000000-0000-0000-0000-000000000000" },
        caller_id: "u-1",
        caller_scopes: [:"write:api_keys"]
      )
      expect(result[:ok]).to be false
      expect(result[:error]).to eq("api_key_not_found")
    end

    it "rejette l'appel sans le scope write:api_keys" do
      expect {
        tool.call(
          params: { id: "x" },
          caller_id: "u-1",
          caller_scopes: [:"read:api_keys"]
        )
      }.to raise_error(Mcp::ScopeError, /write:api_keys/)
    end
  end

  describe "round-trip list_api_keys / revoke_api_key" do
    it "list voit la cle, revoke, list voit revoked_at non-nil" do
      list_tool   = Mcp::ToolRegistry.fetch("list_api_keys")
      revoke_tool = Mcp::ToolRegistry.fetch("revoke_api_key")
      record, _raw = api_key_storage.create_for(user_id: "u-1")

      before_revoke = list_tool.call(
        params: { user_id: "u-1" },
        caller_id: "u-1",
        caller_scopes: [:"read:api_keys"]
      )
      expect(before_revoke[:api_keys].first[:revoked_at]).to be_nil

      revoke_tool.call(
        params: { id: record.id },
        caller_id: "u-1",
        caller_scopes: [:"write:api_keys"]
      )

      after_revoke = list_tool.call(
        params: { user_id: "u-1" },
        caller_id: "u-1",
        caller_scopes: [:"read:api_keys"]
      )
      expect(after_revoke[:api_keys].first[:revoked_at]).not_to be_nil
    end
  end
end
