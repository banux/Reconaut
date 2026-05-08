# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/mcp/core_tools"
require_relative "../../../app/use_cases/scopes/storage"

# Specs du tool MCP ingest_scan_result ajouté par
# openspec/changes/reposition-as-agent-knowledge-base/specs/integrations/spec.md.
RSpec.describe "Mcp::CoreTools ingest_scan_result tool" do
  let(:retriever) { instance_double(Agent::HybridRetriever) }
  let(:scope_storage) { Scopes::Storage::InMemory.new }
  let(:ingestion_recorder) { TestRecorder.new }

  # Recorder en mémoire qui imite l'API attendue par ingest_scan_result :
  # seen?(idem_key) + record!(idem_key, payload:, caller_id:).
  class TestRecorder
    def initialize
      @seen = {}
    end

    def seen?(key)
      @seen.key?(key)
    end

    def record!(key, payload:, caller_id:)
      @seen[key] = { payload: payload, caller_id: caller_id, recorded_at: Time.now }
    end

    def all = @seen.dup
  end

  let(:valid_payload) do
    {
      "schema_version"  => 1,
      "job_id"          => "job-12345678",
      "idempotency_key" => "scan-20260508-1200-deadbeefcafebabe",
      "target"          => { "kind" => "ip", "value" => "192.0.2.10" },
      "status"          => "success",
      "observed_at"     => "2026-05-08T12:00:00Z",
      "findings"        => [{ "port" => 22, "service" => "ssh" }],
      "source"          => "nmap"
    }
  end

  before do
    Mcp::ToolRegistry.reset!
    Mcp::CoreTools.register_all!(
      retriever:          retriever,
      scope_storage:      scope_storage,
      ingestion_recorder: ingestion_recorder
    )
  end

  let(:tool) { Mcp::ToolRegistry.fetch("ingest_scan_result") }

  it "expose le scope write:scans et un schema accept payload hash" do
    expect(tool.scopes).to eq([:"write:scans"])
    expect(tool.params_schema.keys).to contain_exactly(:payload)
    expect(tool.params_schema[:payload][:type]).to eq(:hash)
  end

  it "happy path : payload valide, cible dans le scope, ingestion enregistree" do
    scope_storage.create(kind: "ip", value: "192.0.2.10")

    result = tool.call(
      params: { payload: valid_payload },
      caller_id: "u-1",
      caller_scopes: [:"write:scans"]
    )

    expect(result[:ok]).to be true
    expect(result[:outcome]).to eq("ingested")
    expect(result[:idempotency_key]).to eq("scan-20260508-1200-deadbeefcafebabe")
    expect(result[:job_id]).to eq("job-12345678")
    expect(result[:source]).to eq("nmap")
    expect(ingestion_recorder.all.keys).to include("scan-20260508-1200-deadbeefcafebabe")
  end

  it "rejette un payload mal forme avec invalid_payload + liste d'erreurs" do
    bad = valid_payload.merge("schema_version" => 99)
    result = tool.call(
      params: { payload: bad },
      caller_id: "u-1",
      caller_scopes: [:"write:scans"]
    )
    expect(result[:ok]).to be false
    expect(result[:error]).to eq("invalid_payload")
    expect(result[:errors]).to be_an(Array)
    expect(result[:errors].any? { |e| e.include?("schema_version") }).to be true
  end

  it "rejette une cible hors scope avec out-of-scope" do
    # scope_storage est vide — toute cible est hors scope
    result = tool.call(
      params: { payload: valid_payload },
      caller_id: "u-1",
      caller_scopes: [:"write:scans"]
    )
    expect(result[:ok]).to be false
    expect(result[:error]).to eq("out-of-scope")
    expect(result[:target]).to eq(kind: "ip", value: "192.0.2.10")
    expect(ingestion_recorder.all).to be_empty
  end

  it "idempotence : meme idempotency_key reinjectee renvoie outcome=duplicate" do
    scope_storage.create(kind: "ip", value: "192.0.2.10")

    first = tool.call(
      params: { payload: valid_payload },
      caller_id: "u-1",
      caller_scopes: [:"write:scans"]
    )
    expect(first[:outcome]).to eq("ingested")

    second = tool.call(
      params: { payload: valid_payload },
      caller_id: "u-1",
      caller_scopes: [:"write:scans"]
    )
    expect(second[:ok]).to be true
    expect(second[:outcome]).to eq("duplicate")
    expect(ingestion_recorder.all.size).to eq(1)
  end

  it "rejette l'appel sans le scope write:scans" do
    expect {
      tool.call(
        params: { payload: valid_payload },
        caller_id: "u-1",
        caller_scopes: [:"read:scans"]
      )
    }.to raise_error(Mcp::ScopeError, /write:scans/)
  end

  it "rejette un payload non-hash via coerce_params" do
    expect {
      tool.call(
        params: { payload: "not a hash" },
        caller_id: "u-1",
        caller_scopes: [:"write:scans"]
      )
    }.to raise_error(Mcp::ParamTypeError, /payload.*hash/i)
  end

  it "source par defaut = external quand le payload n'a pas de champ source" do
    scope_storage.create(kind: "ip", value: "192.0.2.10")
    payload_no_source = valid_payload.dup.tap { |h| h.delete("source") }

    result = tool.call(
      params: { payload: payload_no_source },
      caller_id: "u-1",
      caller_scopes: [:"write:scans"]
    )
    expect(result[:ok]).to be true
    expect(result[:source]).to eq("external")
  end

  it "fonctionne sans ingestion_recorder injecte (idempotence inactive)" do
    Mcp::ToolRegistry.reset!
    Mcp::CoreTools.register_all!(
      retriever:     retriever,
      scope_storage: scope_storage
      # pas d'ingestion_recorder
    )
    scope_storage.create(kind: "ip", value: "192.0.2.10")

    tool_no_rec = Mcp::ToolRegistry.fetch("ingest_scan_result")
    result1 = tool_no_rec.call(
      params: { payload: valid_payload },
      caller_id: "u-1",
      caller_scopes: [:"write:scans"]
    )
    result2 = tool_no_rec.call(
      params: { payload: valid_payload },
      caller_id: "u-1",
      caller_scopes: [:"write:scans"]
    )
    # Sans recorder, les deux appels passent comme "ingested"
    expect(result1[:outcome]).to eq("ingested")
    expect(result2[:outcome]).to eq("ingested")
  end
end
