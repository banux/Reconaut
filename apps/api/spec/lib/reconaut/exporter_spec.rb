# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# Cf. openspec/changes/add-mcp-engine/specs/mcp-server/spec.md
#   -> Requirement: MCP Tool `export_report`

RSpec.describe Reconaut::Exporter do
  let(:tmpdir) { Dir.mktmpdir("reconaut-export-spec") }

  after { FileUtils.rm_rf(tmpdir) }

  let(:hosts_data) do
    [
      { id: "h1", ip: "192.0.2.10", fqdn: nil,                 first_seen_at: "2026-05-01", last_seen_at: "2026-05-09" },
      { id: "h2", ip: nil,           fqdn: "mail.example.fr",  first_seen_at: "2026-05-01", last_seen_at: "2026-05-09" }
    ]
  end

  let(:services_data) do
    [
      { id: "s1", host_id: "h1", port: 502, protocol: "tcp", service_name: "modbus", banner: "..." }
    ]
  end

  let(:scope_data) do
    [
      { id: "sc1", kind: "cidr",   value: "192.0.2.0/24",      created_at: "2026-05-01" },
      { id: "sc2", kind: "domain", value: "example.fr",        created_at: "2026-05-01" }
    ]
  end

  describe "JSON" do
    it "produit un Array JSON parseable avec record_count exact" do
      r = described_class.export(kind: "hosts", format: "json",
                                 dest_dir: tmpdir, limit: 100, data: { hosts: hosts_data })
      expect(r.record_count).to eq(2)
      expect(File.exist?(r.path)).to be true
      parsed = JSON.parse(File.read(r.path))
      expect(parsed).to be_an(Array)
      expect(parsed.size).to eq(2)
      expect(parsed.first["ip"]).to eq("192.0.2.10")
    end
  end

  describe "CSV" do
    it "produit RFC4180 : headers + data, valeurs avec virgule quotées" do
      data = { hosts: [{ id: "x", ip: "1.2.3.4", fqdn: "a, b" }] }
      r = described_class.export(kind: "hosts", format: "csv",
                                 dest_dir: tmpdir, data: data)
      content = File.read(r.path)
      expect(content.lines.first.strip).to eq("id,ip,fqdn")
      expect(content).to include('"a, b"') # virgule dans valeur → quoting
    end

    it "Result.format=csv, extension .csv" do
      r = described_class.export(kind: "hosts", format: "csv",
                                 dest_dir: tmpdir, data: { hosts: hosts_data })
      expect(r.format).to eq("csv")
      expect(r.path).to end_with(".csv")
    end
  end

  describe "STIX2 minimal SCO-only" do
    it "produit un bundle STIX2.1 avec ipv4-addr et domain-name" do
      r = described_class.export(kind: "hosts", format: "stix2",
                                 dest_dir: tmpdir, data: { hosts: hosts_data })
      bundle = JSON.parse(File.read(r.path))
      expect(bundle["type"]).to eq("bundle")
      expect(bundle["id"]).to match(/\Abundle--/)
      expect(bundle["objects"]).to be_an(Array)
      types = bundle["objects"].map { |o| o["type"] }.uniq.sort
      expect(types).to include("ipv4-addr", "domain-name")
    end

    it "id STIX au format <type>--<uuid>" do
      r = described_class.export(kind: "hosts", format: "stix2",
                                 dest_dir: tmpdir, data: { hosts: hosts_data })
      bundle = JSON.parse(File.read(r.path))
      bundle["objects"].each do |o|
        expect(o["id"]).to match(/\A[a-z0-9-]+--[0-9a-f-]{36}\z/)
      end
    end

    it "stix2 sur services produit network-traffic avec dst_port + protocols" do
      r = described_class.export(kind: "services", format: "stix2",
                                 dest_dir: tmpdir, data: { services: services_data })
      bundle = JSON.parse(File.read(r.path))
      nt = bundle["objects"].first
      expect(nt["type"]).to eq("network-traffic")
      expect(nt["dst_port"]).to eq(502)
      expect(nt["protocols"]).to eq(["tcp"])
    end

    it "uuid5 déterministe : même input = même id" do
      a = described_class.uuid5("foo")
      b = described_class.uuid5("foo")
      expect(a).to eq(b)
      c = described_class.uuid5("bar")
      expect(c).not_to eq(a)
    end
  end

  describe "limit" do
    it "respecte le limit explicite" do
      data = { hosts: 50.times.map { |i| { id: "h#{i}", ip: "10.0.0.#{i}" } } }
      r = described_class.export(kind: "hosts", format: "json",
                                 dest_dir: tmpdir, limit: 5, data: data)
      expect(r.record_count).to eq(5)
      expect(JSON.parse(File.read(r.path)).size).to eq(5)
    end

    it "clamp à MAX_LIMIT" do
      data = { hosts: 20.times.map { |i| { id: "h#{i}" } } }
      r = described_class.export(kind: "hosts", format: "json",
                                 dest_dir: tmpdir, limit: 999_999, data: data)
      expect(r.record_count).to eq(20) # tout, mais clamp interne respecté
    end
  end

  describe "validation" do
    it "rejette un kind inconnu" do
      expect {
        described_class.export(kind: "users", format: "json",
                               dest_dir: tmpdir, data: { hosts: [] })
      }.to raise_error(Reconaut::Exporter::InvalidParamError, /kind/)
    end

    it "rejette un format inconnu" do
      expect {
        described_class.export(kind: "hosts", format: "yaml",
                               dest_dir: tmpdir, data: { hosts: [] })
      }.to raise_error(Reconaut::Exporter::InvalidParamError, /format/)
    end
  end

  describe "content_type" do
    it "json -> application/json" do
      expect(described_class.content_type("json")).to eq("application/json")
    end

    it "csv -> text/csv" do
      expect(described_class.content_type("csv")).to eq("text/csv")
    end

    it "stix2 -> application/stix+json;version=2.1" do
      expect(described_class.content_type("stix2")).to eq("application/stix+json;version=2.1")
    end
  end

  describe "purge_older_than!" do
    it "supprime les fichiers plus vieux que la fenêtre" do
      old = File.join(tmpdir, "old.json")
      new = File.join(tmpdir, "new.json")
      File.write(old, "[]")
      File.write(new, "[]")
      File.utime(Time.now - 7200, Time.now - 7200, old) # 2h ago
      File.utime(Time.now,         Time.now,         new)

      described_class.purge_older_than!(dir: tmpdir, older_than: 3600)

      expect(File.exist?(old)).to be false
      expect(File.exist?(new)).to be true
    end

    it "no-op si le dir n'existe pas" do
      expect {
        described_class.purge_older_than!(dir: "/tmp/does-not-exist-#{SecureRandom.hex(4)}",
                                          older_than: 60)
      }.not_to raise_error
    end
  end
end
