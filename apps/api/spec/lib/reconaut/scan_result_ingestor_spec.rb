# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/reconaut/scan_result_ingestor"
require_relative "../../../app/use_cases/scopes/storage"

# Cf. openspec/changes/reposition-as-agent-knowledge-base/tasks.md §2.2.
RSpec.describe Reconaut::ScanResultIngestor do
  let(:scope_storage) { Scopes::Storage::InMemory.new }
  let(:recorder) { TestRecorderForIngestor.new }

  class TestRecorderForIngestor
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

  let(:base_payload) do
    {
      "schema_version"  => 1,
      "job_id"          => "job-deadbeef",
      "idempotency_key" => "scan-20260508-1200-aaaa",
      "target"          => { "kind" => "ip", "value" => "192.0.2.10" },
      "status"          => "success",
      "observed_at"     => "2026-05-08T12:00:00Z",
      "findings"        => [{ "port" => 22, "service" => "ssh" }]
    }
  end

  before { scope_storage.create(kind: "ip", value: "192.0.2.10") }

  it "ingère un payload en complétant `source` avec le source_default fourni" do
    result = described_class.call(
      payload:            base_payload,
      scope_storage:      scope_storage,
      ingestion_recorder: recorder,
      caller_id:          "key:abc",
      source_default:     described_class::SOURCE_INTERNAL
    )
    expect(result[:ok]).to be true
    expect(result[:source]).to eq("internal")
  end

  it "ingère un payload en respectant la source explicite (nmap)" do
    payload = base_payload.merge("source" => "nmap")
    result = described_class.call(
      payload:            payload,
      scope_storage:      scope_storage,
      ingestion_recorder: recorder,
      caller_id:          "key:wrapper",
      source_default:     described_class::SOURCE_EXTERNAL
    )
    expect(result[:source]).to eq("nmap")
  end

  it "factorisation cross-source : un même hôte vu par worker interne + nmap collecte deux sources" do
    described_class.call(
      payload:            base_payload.merge("idempotency_key" => "scan-internal-aaaa"),
      scope_storage:      scope_storage,
      ingestion_recorder: recorder,
      source_default:     described_class::SOURCE_INTERNAL
    )
    described_class.call(
      payload:            base_payload.merge("idempotency_key" => "scan-nmap-bbbb", "source" => "nmap"),
      scope_storage:      scope_storage,
      ingestion_recorder: recorder
    )

    sources_seen = recorder.all.values.map { |r| described_class.read_source(r[:payload]) }
    expect(sources_seen).to contain_exactly("internal", "nmap")
  end

  it "rejette out-of-scope quand la cible n'est pas couverte" do
    payload = base_payload.merge("target" => { "kind" => "ip", "value" => "8.8.8.8" })
    result = described_class.call(
      payload:            payload,
      scope_storage:      scope_storage,
      ingestion_recorder: recorder
    )
    expect(result[:ok]).to be false
    expect(result[:error]).to eq("out-of-scope")
  end

  it "supporte les payloads à clés symbol" do
    sym_payload = base_payload.transform_keys(&:to_sym).merge(
      target: { kind: "ip", value: "192.0.2.10" }
    )
    result = described_class.call(
      payload:            sym_payload,
      scope_storage:      scope_storage,
      ingestion_recorder: recorder,
      source_default:     described_class::SOURCE_EXTERNAL
    )
    expect(result[:ok]).to be true
    expect(result[:source]).to eq("external")
  end

  describe ".sources_for" do
    it "renvoie la source enregistrée pour un idempotency_key" do
      described_class.call(
        payload:            base_payload.merge("source" => "nuclei"),
        scope_storage:      scope_storage,
        ingestion_recorder: recorder
      )
      expect(described_class.sources_for(recorder, "scan-20260508-1200-aaaa"))
        .to eq(["nuclei"])
    end
  end
end
