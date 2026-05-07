# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/agent/audit_recorder"

RSpec.describe Agent::AuditRecorder do
  describe ".normalize!" do
    let(:valid_entry) do
      {
        template_id:       "cert_cluster",
        params_normalized: { cert_sha256: "a" * 64 },
        caller_id:         "user-123",
        duration_ms:       80,
        nodes_touched:     12,
        status:            :success
      }
    end

    it "accepte une entree complete" do
      expect(described_class.normalize!(valid_entry)).to be_a(Hash)
    end

    it "rejette une entree manquant un champ requis" do
      expect {
        described_class.normalize!(valid_entry.except(:duration_ms))
      }.to raise_error(described_class::InvalidEntryError, /duration_ms/)
    end

    it "rejette un statut hors enum" do
      expect {
        described_class.normalize!(valid_entry.merge(status: :explosion))
      }.to raise_error(described_class::InvalidEntryError, /invalid status/)
    end

    it "rejette une entree contenant un mot-cle sensible dans params" do
      tainted = valid_entry.merge(
        params_normalized: { password: "hunter2" }
      )
      expect { described_class.normalize!(tainted) }
        .to raise_error(described_class::InvalidEntryError, /sensitive/)

      tainted_token = valid_entry.merge(
        params_normalized: { api_key: "abc" }
      )
      expect { described_class.normalize!(tainted_token) }
        .to raise_error(described_class::InvalidEntryError, /sensitive/)
    end
  end

  describe Agent::AuditRecorder::InMemoryRecorder do
    let(:recorder) { described_class.new }

    it "enregistre les entrees valides" do
      recorder.record(
        template_id: "cert_cluster",
        params_normalized: { cert_sha256: "a" * 64 },
        caller_id: "key-1",
        duration_ms: 50,
        nodes_touched: 3,
        status: :success
      )
      expect(recorder.count).to eq(1)
      expect(recorder.entries.first[:template_id]).to eq("cert_cluster")
    end

    it "couvre tous les statuts (success / timeout / unauthorized / unknown_template / param_invalid / unavailable)" do
      base = {
        template_id: "x",
        params_normalized: {},
        caller_id: "k",
        duration_ms: 0,
        nodes_touched: 0
      }
      Agent::AuditRecorder::VALID_STATUSES.each do |status|
        recorder.record(base.merge(status: status))
      end

      expect(recorder.count).to eq(Agent::AuditRecorder::VALID_STATUSES.length)
      recorded_statuses = recorder.entries.map { |e| e[:status] }
      expect(recorded_statuses).to match_array(Agent::AuditRecorder::VALID_STATUSES)
    end

    it "est thread-safe : 100 ecritures concurrentes ne perdent rien" do
      threads = 10.times.map do |i|
        Thread.new do
          10.times do |j|
            recorder.record(
              template_id: "t",
              params_normalized: { idx: i * 10 + j },
              caller_id: "k",
              duration_ms: 1,
              nodes_touched: 0,
              status: :success
            )
          end
        end
      end
      threads.each(&:join)
      expect(recorder.count).to eq(100)
    end

    it "remet a zero via clear!" do
      recorder.record(
        template_id: "t",
        params_normalized: {},
        caller_id: "k",
        duration_ms: 1,
        nodes_touched: 0,
        status: :success
      )
      recorder.clear!
      expect(recorder.count).to eq(0)
    end

    it "rejette les entrees malformees (forwarde InvalidEntryError)" do
      expect {
        recorder.record(template_id: "t")
      }.to raise_error(Agent::AuditRecorder::InvalidEntryError)
    end
  end
end
