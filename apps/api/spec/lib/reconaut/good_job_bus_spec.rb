# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/reconaut/good_job_bus"

RSpec.describe Reconaut::GoodJobBus do
  include ActiveJob::TestHelper

  let(:payload) do
    {
      "schema_version"  => 1,
      "idempotency_key" => "scan-20260508-1200-cafedeadbeefbabe",
      "scan_kind"       => "tcp_port_scan",
      "target"          => { "kind" => "ip", "value" => "192.0.2.10" },
      "requested_at"    => "2026-05-08T12:00:00Z"
    }
  end

  it "appelle ScanJob.perform_later avec le payload tel quel" do
    expect do
      described_class.new.enqueue(payload: payload)
    end.to have_enqueued_job(ScanJob).with(payload).on_queue("scan")
  end

  it "renvoie { scan_id: <string> } correlable" do
    result = described_class.new.enqueue(payload: payload)
    expect(result).to match(scan_id: kind_of(String))
    expect(result[:scan_id]).not_to be_empty
  end

  it "le scan_id correspond au job_id ActiveJob (en mode :test)" do
    bus = described_class.new
    captured_job = nil
    ActiveSupport::Notifications.subscribed(
      ->(*args) { captured_job ||= ActiveSupport::Notifications::Event.new(*args).payload[:job] },
      "enqueue.active_job"
    ) do
      result = bus.enqueue(payload: payload)
      expect(result[:scan_id]).to eq(captured_job.job_id)
    end
  end

  it "implémente le même contrat que InMemoryJobBus" do
    in_mem = Reconaut::ScanEnqueuer::InMemoryJobBus.new
    in_mem_result = in_mem.enqueue(payload: payload)

    good_job_result = described_class.new.enqueue(payload: payload)

    # Les deux implémentations renvoient un Hash avec la même clé `scan_id`.
    expect(in_mem_result.keys).to eq(good_job_result.keys)
    expect(in_mem_result[:scan_id]).to be_a(String)
    expect(good_job_result[:scan_id]).to be_a(String)
  end
end
