# frozen_string_literal: true

# Tests directs du registry. Aucun rails_helper requis : on teste de la
# logique pure (lecture de fichier + validation JSON Schema).
require "spec_helper"
require_relative "../../../app/lib/job_schema/registry"

RSpec.describe JobSchema::Registry do
  describe ".names" do
    it "expose les trois schemas requis par add-tech-stack" do
      expect(described_class.names).to contain_exactly(
        "ScanJobV1", "ScanResultV1", "HeartbeatV1"
      )
    end
  end

  describe ".load" do
    it "charge un schema connu" do
      schema = described_class.load("ScanJobV1")
      expect(schema["title"]).to eq("ScanJobV1")
      expect(schema["properties"]["schema_version"]["const"]).to eq(1)
    end

    it "leve UnknownSchemaError sur un schema inconnu" do
      expect { described_class.load("Bogus") }
        .to raise_error(JobSchema::UnknownSchemaError)
    end
  end

  describe ".validate (ScanJobV1)" do
    let(:valid_payload) do
      {
        "schema_version"  => 1,
        "idempotency_key" => "scan-2026-05-07-host-1234",
        "scan_kind"       => "tcp_probe",
        "target"          => { "kind" => "ip", "value" => "192.0.2.1" },
        "requested_at"    => "2026-05-07T08:30:00Z"
      }
    end

    it "accepte un payload conforme" do
      ok, errors = described_class.validate("ScanJobV1", valid_payload)
      expect(errors).to be_empty
      expect(ok).to be true
    end

    it "rejette un schema_version != 1" do
      payload = valid_payload.merge("schema_version" => 99)
      ok, errors = described_class.validate("ScanJobV1", payload)
      expect(ok).to be false
      expect(errors.join(" ")).to match(/schema_version/i)
    end

    it "rejette un scan_kind inconnu" do
      payload = valid_payload.merge("scan_kind" => "icmp_flood")
      ok, errors = described_class.validate("ScanJobV1", payload)
      expect(ok).to be false
    end

    it "rejette un target.kind inconnu" do
      payload = valid_payload.merge("target" => { "kind" => "person", "value" => "alice" })
      ok, errors = described_class.validate("ScanJobV1", payload)
      expect(ok).to be false
    end

    it "rejette un payload incomplet" do
      payload = valid_payload.reject { |k, _| k == "requested_at" }
      ok, errors = described_class.validate("ScanJobV1", payload)
      expect(ok).to be false
      expect(errors.join(" ")).to match(/requested_at/)
    end

    it "rejette une propriete supplementaire" do
      payload = valid_payload.merge("evil_field" => true)
      ok, errors = described_class.validate("ScanJobV1", payload)
      expect(ok).to be false
    end
  end

  describe ".validate (ScanResultV1)" do
    let(:valid_payload) do
      {
        "schema_version"  => 1,
        "job_id"          => "job-12345678",
        "idempotency_key" => "scan-2026-05-07-host-1234",
        "target"          => { "kind" => "ip", "value" => "192.0.2.1" },
        "status"          => "success",
        "observed_at"     => "2026-05-07T08:31:00Z",
        "findings"        => [{ "port" => 443, "proto" => "tls" }]
      }
    end

    it "accepte un payload conforme" do
      ok, errors = described_class.validate("ScanResultV1", valid_payload)
      expect(errors).to be_empty
      expect(ok).to be true
    end

    it "rejette un status inconnu" do
      payload = valid_payload.merge("status" => "lol")
      ok, _errors = described_class.validate("ScanResultV1", payload)
      expect(ok).to be false
    end
  end

  describe ".validate (HeartbeatV1)" do
    it "accepte un battement minimal" do
      payload = {
        "schema_version" => 1,
        "worker_id"      => "worker-eu-west-1",
        "emitted_at"     => "2026-05-07T08:30:00Z",
        "inflight_jobs"  => 3
      }
      ok, errors = described_class.validate("HeartbeatV1", payload)
      expect(errors).to be_empty
      expect(ok).to be true
    end

    it "rejette inflight_jobs negatif" do
      payload = {
        "schema_version" => 1,
        "worker_id"      => "worker",
        "emitted_at"     => "2026-05-07T08:30:00Z",
        "inflight_jobs"  => -1
      }
      ok, _errors = described_class.validate("HeartbeatV1", payload)
      expect(ok).to be false
    end
  end

  describe ".schema_version_for / .schema_versions" do
    it "schema_version_for(\"ScanJobV1\") renvoie la const declaree" do
      expect(described_class.schema_version_for("ScanJobV1")).to eq(1)
    end

    it "schema_versions enumere les trois schemas connus avec leurs versions" do
      versions = described_class.schema_versions
      expect(versions.keys).to contain_exactly("ScanJobV1", "ScanResultV1", "HeartbeatV1")
      expect(versions.values).to all(be_an(Integer))
    end

    it "schema_version_for sur un schema inconnu leve UnknownSchemaError" do
      expect {
        described_class.schema_version_for("Unknown")
      }.to raise_error(JobSchema::UnknownSchemaError)
    end
  end
end
