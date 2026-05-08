# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/reconaut/heartbeats"

RSpec.describe Reconaut::Heartbeats::InMemoryStore do
  subject(:store) { described_class.new }

  let(:payload) do
    {
      "schema_version" => 1,
      "worker_id"      => "scanner-tcp-01",
      "version"        => "0.1.2",
      "emitted_at"     => "2026-05-08T12:00:00Z",
      "inflight_jobs"  => 3
    }
  end

  it "record! retourne un Record avec les champs essentiels" do
    record = store.record!(payload)
    expect(record.worker_id).to eq("scanner-tcp-01")
    expect(record.worker_version).to eq("0.1.2")
    expect(record.schema_version).to eq(1)
    expect(record.inflight_jobs).to eq(3)
    expect(record.seen_at).to eq("2026-05-08T12:00:00Z")
  end

  it "latest renvoie le dernier heartbeat enregistre tous workers confondus" do
    store.record!(payload)
    later = payload.merge("worker_id" => "scanner-tls-02", "emitted_at" => "2026-05-08T12:05:00Z")
    store.record!(later)

    latest = store.latest
    expect(latest.worker_id).to eq("scanner-tls-02")
  end

  it "list renvoie la dernière heartbeat par worker_id (un par worker)" do
    store.record!(payload)
    store.record!(payload.merge("inflight_jobs" => 5)) # même worker, mise à jour

    expect(store.list.size).to eq(1)
    expect(store.list.first.inflight_jobs).to eq(5)
  end

  it "to_h serialisable sans password ni token" do
    record = store.record!(payload)
    h = record.to_h
    expect(h.keys).to contain_exactly(:worker_id, :worker_version, :schema_version, :inflight_jobs, :seen_at)
  end

  it "fallback seen_at sur le clock injecté quand emitted_at absent" do
    fixed_time = Time.utc(2026, 5, 8, 13, 0, 0)
    store_with_clock = described_class.new(clock: -> { fixed_time })
    record = store_with_clock.record!(payload.tap { |h| h.delete("emitted_at") })
    expect(record.seen_at).to eq(fixed_time.iso8601)
  end
end
