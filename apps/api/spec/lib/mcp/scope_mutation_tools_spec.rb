# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/mcp/core_tools"
require_relative "../../../app/use_cases/scopes/storage"

# Specs des tools MCP add_scope et revoke_scope ajoutes par
# openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md.
RSpec.describe "Mcp::CoreTools scope mutation tools" do
  let(:retriever) { instance_double(Agent::HybridRetriever) }
  let(:scope_storage) { Scopes::Storage::InMemory.new }

  before do
    Mcp::ToolRegistry.reset!
    Mcp::CoreTools.register_all!(
      retriever:     retriever,
      scope_storage: scope_storage
    )
  end

  describe "add_scope" do
    let(:tool) { Mcp::ToolRegistry.fetch("add_scope") }

    it "expose le scope write:scopes et un schema kind+value" do
      expect(tool.scopes).to eq([:"write:scopes"])
      expect(tool.params_schema.keys).to contain_exactly(:kind, :value)
    end

    it "happy path : cree une entree et la renvoie" do
      result = tool.call(
        params: { kind: "cidr", value: "192.0.2.0/24" },
        caller_id: "u-1",
        caller_scopes: [:"write:scopes"]
      )
      expect(result[:ok]).to be true
      expect(result[:scope][:kind]).to eq("cidr")
      expect(result[:scope][:value]).to eq("192.0.2.0/24")
      expect(result[:scope][:id]).to be_a(String)
      expect(scope_storage.list.size).to eq(1)
    end

    it "rejette un kind hors enum (au niveau du params_schema)" do
      expect {
        tool.call(
          params: { kind: "xxx", value: "192.0.2.0/24" },
          caller_id: "u-1",
          caller_scopes: [:"write:scopes"]
        )
      }.to raise_error(Mcp::ParamOutOfRangeError, /kind/)
    end

    it "rejette un value vide (au niveau du params_schema)" do
      expect {
        tool.call(
          params: { kind: "cidr", value: "" },
          caller_id: "u-1",
          caller_scopes: [:"write:scopes"]
        )
      }.to raise_error(Mcp::ParamOutOfRangeError, /value/)
    end

    it "rejette l'appel sans le scope write:scopes" do
      expect {
        tool.call(
          params: { kind: "cidr", value: "192.0.2.0/24" },
          caller_id: "u-1",
          caller_scopes: [:"read:scopes"] # lecture seule
        )
      }.to raise_error(Mcp::ScopeError, /write:scopes/)
    end
  end

  describe "revoke_scope" do
    let(:tool) { Mcp::ToolRegistry.fetch("revoke_scope") }

    it "expose le scope write:scopes et un schema id" do
      expect(tool.scopes).to eq([:"write:scopes"])
      expect(tool.params_schema.keys).to contain_exactly(:id)
    end

    it "happy path : revoque une entree existante" do
      created = scope_storage.create(kind: "cidr", value: "192.0.2.0/24")
      result = tool.call(
        params: { id: created.id },
        caller_id: "u-1",
        caller_scopes: [:"write:scopes"]
      )
      expect(result[:ok]).to be true
      expect(result[:id]).to eq(created.id)
      expect(scope_storage.list.size).to eq(0)
    end

    it "renvoie scope_not_found pour un id inconnu" do
      result = tool.call(
        params: { id: "00000000-0000-0000-0000-000000000000" },
        caller_id: "u-1",
        caller_scopes: [:"write:scopes"]
      )
      expect(result[:ok]).to be false
      expect(result[:error]).to eq("scope_not_found")
    end

    it "rejette l'appel sans le scope write:scopes" do
      expect {
        tool.call(
          params: { id: "x" },
          caller_id: "u-1",
          caller_scopes: [:"read:scopes"]
        )
      }.to raise_error(Mcp::ScopeError, /write:scopes/)
    end
  end

  describe "interaction list_scopes / add_scope / revoke_scope" do
    it "round-trip : add puis list voit l'entree, revoke puis list ne la voit plus" do
      add_tool    = Mcp::ToolRegistry.fetch("add_scope")
      list_tool   = Mcp::ToolRegistry.fetch("list_scopes")
      revoke_tool = Mcp::ToolRegistry.fetch("revoke_scope")

      added = add_tool.call(
        params: { kind: "domain", value: "example.test" },
        caller_id: "u-1",
        caller_scopes: [:"write:scopes"]
      )
      expect(added[:ok]).to be true

      listed = list_tool.call(
        params: {},
        caller_id: "u-1",
        caller_scopes: [:"read:scopes"]
      )
      expect(listed[:scopes].map { |s| s[:value] }).to include("example.test")

      revoked = revoke_tool.call(
        params: { id: added[:scope][:id] },
        caller_id: "u-1",
        caller_scopes: [:"write:scopes"]
      )
      expect(revoked[:ok]).to be true

      listed_after = list_tool.call(
        params: {},
        caller_id: "u-1",
        caller_scopes: [:"read:scopes"]
      )
      expect(listed_after[:scopes]).to eq([])
    end
  end
end
