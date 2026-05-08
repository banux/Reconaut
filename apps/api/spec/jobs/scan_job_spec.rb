# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScanJob do
  let(:payload) do
    {
      "schema_version"  => 1,
      "idempotency_key" => "scan-20260508-1200-deadbeefcafebabe",
      "scan_kind"       => "tcp_port_scan",
      "target"          => { "kind" => "ip", "value" => "192.0.2.10" },
      "requested_at"    => "2026-05-08T12:00:00Z"
    }
  end

  it "est routé sur la queue :scan" do
    expect(ScanJob.queue_name).to eq("scan")
  end

  it "enqueue un job avec le payload sérialisé tel quel" do
    expect do
      described_class.perform_later(payload)
    end.to have_enqueued_job(described_class).with(payload).on_queue("scan")
  end

  it "refuse de tourner côté Rails (la logique de scan est dans le worker Go)" do
    job = described_class.new(payload)
    expect { job.perform_now }.to raise_error(
      NotImplementedError,
      /scan logic\s+lives in the Go worker/m
    )
  end
end
