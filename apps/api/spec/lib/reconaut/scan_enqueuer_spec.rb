# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/reconaut/scan_enqueuer"
require_relative "../../../app/use_cases/scopes/storage"

RSpec.describe Reconaut::ScanEnqueuer do
  let(:storage) { Scopes::Storage::InMemory.new }
  let(:bus)     { Reconaut::ScanEnqueuer::InMemoryJobBus.new }

  subject(:enqueuer) { described_class.new(scope_storage: storage, job_bus: bus) }

  describe "scope enforcement" do
    it "rejette une cible hors scope avec OutOfScopeError" do
      expect {
        enqueuer.call(scan_kind: "tcp_probe", target_kind: "ip", target_value: "8.8.8.8")
      }.to raise_error(described_class::OutOfScopeError, /out-of-scope/)
    end

    it "accepte une cible dans le scope" do
      storage.create(kind: "ip", value: "192.0.2.1")
      result = enqueuer.call(scan_kind: "tcp_probe", target_kind: "ip", target_value: "192.0.2.1")
      expect(result.scan_id).to be_a(String)
    end
  end

  describe "validation ScanJobV1" do
    before { storage.create(kind: "ip", value: "192.0.2.1") }

    it "rejette un scan_kind hors enum" do
      expect {
        enqueuer.call(scan_kind: "icmp_flood", target_kind: "ip", target_value: "192.0.2.1")
      }.to raise_error(described_class::InvalidPayloadError, /scan_kind/)
    end

    it "construit un payload valide ScanJobV1 avec target.kind / value" do
      enqueuer.call(scan_kind: "tcp_probe", target_kind: "ip", target_value: "192.0.2.1")
      payload = bus.jobs.last[:payload]
      expect(payload["schema_version"]).to eq(1)
      expect(payload["scan_kind"]).to eq("tcp_probe")
      expect(payload["target"]).to eq("kind" => "ip", "value" => "192.0.2.1")
      expect(payload["idempotency_key"]).to start_with("scan-")
      expect(payload["requested_at"]).to match(/\A2\d{3}-\d{2}-\d{2}T/)
    end
  end

  describe "idempotency_key" do
    before { storage.create(kind: "ip", value: "192.0.2.1") }

    it "est deterministe pour la meme cible dans la meme minute" do
      ts = Time.utc(2026, 5, 7, 10, 30, 0)
      a = enqueuer.call(scan_kind: "tcp_probe", target_kind: "ip",
                        target_value: "192.0.2.1", requested_at: ts)
      b = enqueuer.call(scan_kind: "tcp_probe", target_kind: "ip",
                        target_value: "192.0.2.1", requested_at: ts + 30)
      expect(a.idempotency_key).to eq(b.idempotency_key)
    end

    it "differe pour deux cibles distinctes" do
      storage.create(kind: "ip", value: "192.0.2.2")
      ts = Time.utc(2026, 5, 7, 10, 30, 0)
      a = enqueuer.call(scan_kind: "tcp_probe", target_kind: "ip",
                        target_value: "192.0.2.1", requested_at: ts)
      b = enqueuer.call(scan_kind: "tcp_probe", target_kind: "ip",
                        target_value: "192.0.2.2", requested_at: ts)
      expect(a.idempotency_key).not_to eq(b.idempotency_key)
    end
  end

  describe "job_bus" do
    before { storage.create(kind: "ip", value: "192.0.2.1") }

    it "delegue l'enqueue et persiste le job avec le scan_id" do
      result = enqueuer.call(scan_kind: "tcp_probe", target_kind: "ip", target_value: "192.0.2.1")
      expect(bus.size).to eq(1)
      expect(bus.jobs.first[:scan_id]).to eq(result.scan_id)
    end
  end
end
