# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScanJob do
  let(:payload) do
    {
      "schema_version"  => 1,
      "idempotency_key" => "scan-20260508-1200-deadbeefcafebabe",
      "scan_kind"       => "tcp_probe",
      "target"          => { "kind" => "ip", "value" => "192.0.2.10" },
      "requested_at"    => "2026-05-08T12:00:00Z"
    }
  end

  describe "queue_as dynamique (cf. replace-web-with-tui §3.2)" do
    it "route sur scan:<scan_kind> dérivé du payload (tcp_probe)" do
      expect do
        described_class.perform_later(payload)
      end.to have_enqueued_job(described_class).on_queue("scan:tcp_probe")
    end

    it "tls_capture est routé sur scan:tls_capture" do
      tls = payload.merge("scan_kind" => "tls_capture")
      expect do
        described_class.perform_later(tls)
      end.to have_enqueued_job(described_class).on_queue("scan:tls_capture")
    end

    it "http_banner est routé sur scan:http_banner" do
      http = payload.merge("scan_kind" => "http_banner")
      expect do
        described_class.perform_later(http)
      end.to have_enqueued_job(described_class).on_queue("scan:http_banner")
    end

    it "subdomain_enum est routé sur scan:subdomain_enum" do
      sub = payload.merge("scan_kind" => "subdomain_enum")
      expect do
        described_class.perform_later(sub)
      end.to have_enqueued_job(described_class).on_queue("scan:subdomain_enum")
    end

    it "service_fingerprint est routé sur scan:service_fingerprint" do
      svc = payload.merge("scan_kind" => "service_fingerprint")
      expect do
        described_class.perform_later(svc)
      end.to have_enqueued_job(described_class).on_queue("scan:service_fingerprint")
    end

    it "fallback : payload sans scan_kind retombe sur la queue 'scan'" do
      bad = payload.dup
      bad.delete("scan_kind")
      expect do
        described_class.perform_later(bad)
      end.to have_enqueued_job(described_class).on_queue("scan")
    end
  end

  it "refuse de tourner côté Rails (la logique de scan est dans le worker Go)" do
    job = described_class.new(payload)
    expect { job.perform_now }.to raise_error(
      NotImplementedError,
      /scan logic\s+lives in the Go worker/m
    )
  end
end
