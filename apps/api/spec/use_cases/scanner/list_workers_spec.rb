# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/use_cases/scanner/list_workers"
require_relative "../../../app/lib/reconaut/heartbeats"

# Cf. openspec/changes/add-worker-observability/specs/mcp-server/spec.md
#   -> Requirement: MCP Tool `list_workers`

RSpec.describe Scanner::ListWorkers do
  let(:store) { Reconaut::Heartbeats::InMemoryStore.new }
  let(:now)   { Time.utc(2026, 5, 13, 20, 0, 0) }
  let(:clock) { -> { now } }

  subject(:use_case) { described_class.new(heartbeat_store: store, clock: clock) }

  def record!(worker_id:, scan_kind: "dns_records", seen_at:, inflight: 0, version: "0.0.0")
    store.record!(
      "schema_version" => 1,
      "worker_id"      => worker_id,
      "emitted_at"     => seen_at.utc.iso8601,
      "inflight_jobs"  => inflight,
      "version"        => version,
      "scan_kind"      => scan_kind
    )
  end

  it "retourne les workers vus dans la fenêtre (défaut 300s)" do
    record!(worker_id: "fresh-A", seen_at: now - 10)
    record!(worker_id: "fresh-B", seen_at: now - 60)
    record!(worker_id: "old-C",   seen_at: now - 600)

    result = use_case.call(recent_seconds: 300)
    expect(result.status).to eq(:ok)
    workers = result.body[:workers]
    expect(workers.map { |w| w[:worker_id] }).to contain_exactly("fresh-A", "fresh-B")
  end

  it "trie par age croissant (le plus récent en premier)" do
    record!(worker_id: "B", seen_at: now - 120)
    record!(worker_id: "A", seen_at: now - 5)
    record!(worker_id: "C", seen_at: now - 60)

    result = use_case.call(recent_seconds: 300)
    expect(result.body[:workers].map { |w| w[:worker_id] }).to eq(["A", "C", "B"])
  end

  it "calcule seconds_since_last_seen" do
    record!(worker_id: "W", seen_at: now - 42)

    result = use_case.call(recent_seconds: 300)
    expect(result.body[:workers].first[:seconds_since_last_seen]).to eq(42)
  end

  it "expose scan_kind et version" do
    record!(worker_id: "W", scan_kind: "service_fingerprint", version: "0.1.2", seen_at: now - 10)

    result = use_case.call
    w = result.body[:workers].first
    expect(w[:scan_kind]).to eq("service_fingerprint")
    expect(w[:version]).to eq("0.1.2")
  end

  it "retourne un body vide quand aucun heartbeat" do
    result = use_case.call
    expect(result.body[:workers]).to eq([])
  end

  it "clampe recent_seconds invalide vers le défaut" do
    record!(worker_id: "W", seen_at: now - 30)

    result = use_case.call(recent_seconds: 0)
    expect(result.body[:workers].size).to eq(1)
  end

  it "clampe recent_seconds > 3600 à 3600" do
    record!(worker_id: "W", seen_at: now - 1800)

    result = use_case.call(recent_seconds: 99_999)
    # Le worker est à -1800s, dans la fenêtre 0..3600 → retourné.
    expect(result.body[:workers].size).to eq(1)
  end
end
