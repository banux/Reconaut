# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/reconaut/registry"

RSpec.describe "Reconaut::Registry heartbeat store wiring" do
  before { Reconaut::Registry.reset! }
  after  { Reconaut::Registry.reset! }

  it "expose un heartbeat_store par défaut" do
    registry = Reconaut::Registry.default
    expect(registry.heartbeat_store).to be_a(Reconaut::Heartbeats::InMemoryStore)
    expect(registry.heartbeat_store.latest).to be_nil
  end

  it "le heartbeat_store enregistre persiste entre les accès Registry.default" do
    Reconaut::Registry.default.heartbeat_store.record!(
      "schema_version" => 1,
      "worker_id"      => "scanner-tcp-01",
      "version"        => "0.1.2",
      "emitted_at"     => "2026-05-08T12:00:00Z",
      "inflight_jobs"  => 1
    )
    # Second accès via Registry.default doit voir le même store.
    latest = Reconaut::Registry.default.heartbeat_store.latest
    expect(latest).not_to be_nil
    expect(latest.worker_id).to eq("scanner-tcp-01")
  end

  it "remplaçable pour les tests qui veulent un stub" do
    fake_payload = { worker_id: "fake", worker_version: "x.y.z" }
    fake_record = Class.new {
      def initialize(payload) = (@payload = payload)
      def to_h = @payload
    }.new(fake_payload)
    fake_store = Class.new {
      def initialize(record) = (@record = record)
      def latest = @record
    }.new(fake_record)
    Reconaut::Registry.default.heartbeat_store = fake_store
    latest = Reconaut::Registry.default.heartbeat_store.latest
    expect(latest.to_h).to eq(fake_payload)
  end
end
