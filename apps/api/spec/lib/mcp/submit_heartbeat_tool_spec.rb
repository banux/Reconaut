# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/mcp/core_tools"
require_relative "../../../app/use_cases/scopes/storage"

RSpec.describe "Mcp::CoreTools submit_heartbeat tool" do
  let(:retriever) { instance_double(Agent::HybridRetriever) }
  let(:scope_storage) { Scopes::Storage::InMemory.new }
  let(:heartbeat_store) { Reconaut::Heartbeats::InMemoryStore.new }

  let(:valid_payload) do
    {
      "schema_version" => 1,
      "worker_id"      => "scanner-tcp-01",
      "version"        => "0.1.2",
      "emitted_at"     => "2026-05-08T12:00:00Z",
      "inflight_jobs"  => 3
    }
  end

  before do
    Mcp::ToolRegistry.reset!
    Mcp::CoreTools.register_all!(
      retriever:       retriever,
      scope_storage:   scope_storage,
      heartbeat_store: heartbeat_store
    )
  end

  let(:tool) { Mcp::ToolRegistry.fetch("submit_heartbeat") }

  it "expose le scope write:heartbeats et un schema { payload: hash }" do
    expect(tool.scopes).to eq([:"write:heartbeats"])
    expect(tool.params_schema.keys).to contain_exactly(:payload)
    expect(tool.params_schema[:payload][:type]).to eq(:hash)
  end

  it "happy path : enregistre la heartbeat et expose le record" do
    result = tool.call(
      params: { payload: valid_payload },
      caller_id: "operator",
      caller_scopes: [:"write:heartbeats"]
    )
    expect(result[:ok]).to be true
    expect(result[:recorded][:worker_id]).to eq("scanner-tcp-01")
    expect(result[:recorded][:worker_version]).to eq("0.1.2")
    expect(heartbeat_store.latest.worker_id).to eq("scanner-tcp-01")
  end

  it "rejette un payload mal formé avec invalid_payload" do
    bad = valid_payload.merge("schema_version" => 99)
    result = tool.call(
      params: { payload: bad },
      caller_id: "operator",
      caller_scopes: [:"write:heartbeats"]
    )
    expect(result[:ok]).to be false
    expect(result[:error]).to eq("invalid_payload")
    expect(result[:errors]).to be_an(Array)
    expect(heartbeat_store.list).to be_empty
  end

  it "rejette l'appel sans le scope write:heartbeats" do
    expect {
      tool.call(
        params: { payload: valid_payload },
        caller_id: "operator",
        caller_scopes: [:"read:health"]
      )
    }.to raise_error(Mcp::ScopeError, /write:heartbeats/)
  end

  it "n'est pas enregistré si heartbeat_store n'est pas injecté" do
    Mcp::ToolRegistry.reset!
    Mcp::CoreTools.register_all!(retriever: retriever, scope_storage: scope_storage)
    expect(Mcp::ToolRegistry.names).not_to include("submit_heartbeat")
  end
end
