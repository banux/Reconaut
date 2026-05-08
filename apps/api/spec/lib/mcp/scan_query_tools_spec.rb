# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/mcp/core_tools"
require_relative "../../../app/lib/reconaut/scans"
require_relative "../../../app/use_cases/scopes/storage"

# Specs des tools MCP de lecture des scans : list_scans / get_scan_status.
# Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
# (Requirement: MCP Tool Surface, scope read:scans).
RSpec.describe "Mcp::CoreTools scan query tools" do
  let(:retriever) { instance_double(Agent::HybridRetriever) }
  let(:scope_storage) { Scopes::Storage::InMemory.new }
  let(:scan_store)    { Reconaut::Scans::InMemoryStore.new }

  before do
    Mcp::ToolRegistry.reset!
    Mcp::CoreTools.register_all!(
      retriever:     retriever,
      scope_storage: scope_storage,
      scan_store:    scan_store
    )
  end

  describe "list_scans" do
    let(:tool) { Mcp::ToolRegistry.fetch("list_scans") }

    it "expose le scope read:scans et un schema limit optionnel" do
      expect(tool.scopes).to eq([:"read:scans"])
      expect(tool.params_schema.keys).to contain_exactly(:limit)
    end

    it "renvoie les scans du plus récent au plus ancien" do
      scan_store.record!(scan_id: "s1", scan_kind: "tcp_probe",
                         target_kind: "ip", target_value: "192.0.2.1",
                         idempotency_key: "scan-1")
      scan_store.record!(scan_id: "s2", scan_kind: "tls_capture",
                         target_kind: "ip", target_value: "192.0.2.2",
                         idempotency_key: "scan-2")

      result = tool.call(
        params:        {},
        caller_id:     "operator",
        caller_scopes: [:"read:scans"]
      )
      expect(result[:scans].map { |s| s[:scan_id] }).to eq(%w[s2 s1])
      expect(result[:scans].first[:status]).to eq("queued")
    end

    it "respecte le limit" do
      5.times { |i|
        scan_store.record!(scan_id: "s#{i}", scan_kind: "tcp_probe",
                           target_kind: "ip", target_value: "192.0.2.1",
                           idempotency_key: "scan-#{i}")
      }

      result = tool.call(
        params:        { limit: 2 },
        caller_id:     "operator",
        caller_scopes: [:"read:scans"]
      )
      expect(result[:scans].size).to eq(2)
    end

    it "rejette sans le scope read:scans" do
      expect {
        tool.call(params: {}, caller_id: "x", caller_scopes: [:"read:hosts"])
      }.to raise_error(Mcp::ScopeError, /read:scans/)
    end

    it "n'est pas enregistré sans scan_store" do
      Mcp::ToolRegistry.reset!
      Mcp::CoreTools.register_all!(retriever: retriever, scope_storage: scope_storage)
      expect(Mcp::ToolRegistry.names).not_to include("list_scans")
    end
  end

  describe "get_scan_status" do
    let(:tool) { Mcp::ToolRegistry.fetch("get_scan_status") }

    it "expose le scope read:scans et un schema scan_id" do
      expect(tool.scopes).to eq([:"read:scans"])
      expect(tool.params_schema.keys).to contain_exactly(:scan_id)
    end

    it "renvoie found:true et le scan correspondant" do
      scan_store.record!(scan_id: "abc", scan_kind: "tcp_probe",
                         target_kind: "ip", target_value: "192.0.2.1",
                         idempotency_key: "scan-abc")
      result = tool.call(
        params:        { scan_id: "abc" },
        caller_id:     "operator",
        caller_scopes: [:"read:scans"]
      )
      expect(result[:found]).to be true
      expect(result[:scan][:scan_id]).to eq("abc")
      expect(result[:scan][:status]).to eq("queued")
    end

    it "renvoie found:false sur un scan_id inconnu" do
      result = tool.call(
        params:        { scan_id: "missing" },
        caller_id:     "operator",
        caller_scopes: [:"read:scans"]
      )
      expect(result[:found]).to be false
      expect(result[:scan_id]).to eq("missing")
    end

    it "rejette sans le scope read:scans" do
      expect {
        tool.call(params: { scan_id: "x" }, caller_id: "u", caller_scopes: [])
      }.to raise_error(Mcp::ScopeError, /read:scans/)
    end
  end
end
