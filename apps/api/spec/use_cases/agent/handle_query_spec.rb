# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/use_cases/agent/handle_query"
require_relative "../../../app/lib/agent/audit_recorder"

RSpec.describe Agent::UseCases::HandleQuery do
  # Fake retriever : renvoie une Response simule.
  class FakeRetriever
    def initialize(response)
      @response = response
    end

    def call(_query) = @response
  end

  let(:rows)      { [{ "host_id" => "h1", "scanned_at" => "2026-05-01" }] }
  let(:citations) { [Agent::HybridRetriever::Citation.new(host_id: "h1", scanned_at: "2026-05-01")] }
  let(:response) do
    Agent::HybridRetriever::Response.new(
      rows: rows, citations: citations, warnings: [],
      retrieval_path: "graph", duration_ms: 30
    )
  end
  let(:audit)     { Agent::AuditRecorder::InMemoryRecorder.new }
  let(:retriever) { FakeRetriever.new(response) }

  subject(:use_case) do
    described_class.new(retriever: retriever, audit_recorder: audit)
  end

  describe "RBAC" do
    it "rejette viewer avec 403 + audit unauthorized" do
      result = use_case.call(query: "hi", caller_role: :viewer, caller_id: "u-1")
      expect(result.status).to eq(:unauthorized)
      expect(result.http_status).to eq(403)
      expect(result.body[:error]).to eq("rbac_forbidden")
      expect(audit.entries.last[:status]).to eq(:unauthorized)
    end

    %i[analyst admin owner].each do |role|
      it "autorise #{role}" do
        result = use_case.call(query: "hi", caller_role: role)
        expect(result.status).to eq(:ok)
        expect(result.http_status).to eq(200)
      end
    end
  end

  describe "validation" do
    it "rejette une query vide avec 400" do
      result = use_case.call(query: "  ", caller_role: :analyst)
      expect(result.status).to eq(:bad_request)
      expect(result.body[:error]).to eq("query_required")
    end

    it "rejette une query nil avec 400" do
      result = use_case.call(query: nil, caller_role: :analyst)
      expect(result.status).to eq(:bad_request)
    end
  end

  describe "shape de la reponse OK" do
    it "renvoie le contrat attendu par apps/web/src/api/agent.js" do
      result = use_case.call(query: "hotes nginx", caller_role: :analyst)
      body = result.body

      expect(body.keys).to contain_exactly(
        :rows, :citations, :warnings, :retrieval_path, :duration_ms
      )
      expect(body[:rows]).to eq(rows)
      expect(body[:retrieval_path]).to eq("graph")
      expect(body[:duration_ms]).to eq(30)
      # citations serialise en hash (pas Struct) pour JSON.
      expect(body[:citations]).to all(be_a(Hash))
      expect(body[:citations].first[:host_id]).to eq("h1")
    end
  end

  describe "audit" do
    it "ecrit une ligne d'audit success en cas de succes" do
      use_case.call(query: "x", caller_role: :analyst, caller_id: "user-42")
      entry = audit.entries.last
      expect(entry[:status]).to eq(:success)
      expect(entry[:caller_id]).to eq("user-42")
      expect(entry[:nodes_touched]).to eq(rows.size)
      expect(entry[:duration_ms]).to eq(30)
    end

    it "ecrit une ligne d'audit param_invalid sur query vide" do
      use_case.call(query: "", caller_role: :analyst)
      expect(audit.entries.last[:status]).to eq(:param_invalid)
    end

    it "ne fait JAMAIS echouer la requete si l'audit leve" do
      broken_audit = Object.new
      def broken_audit.record(*) = raise "audit DB down"

      uc = described_class.new(retriever: retriever, audit_recorder: broken_audit)
      expect { uc.call(query: "x", caller_role: :analyst) }.not_to raise_error
    end
  end

  describe "warnings du retriever" do
    it "propage les warnings (graph_unavailable, etc.) au body" do
      degraded = Agent::HybridRetriever::Response.new(
        rows: [], citations: [], warnings: ["graph_unavailable"],
        retrieval_path: "vector", duration_ms: 10
      )
      uc = described_class.new(
        retriever: FakeRetriever.new(degraded),
        audit_recorder: audit
      )
      result = uc.call(query: "x", caller_role: :analyst)
      expect(result.body[:warnings]).to eq(["graph_unavailable"])
      expect(result.body[:retrieval_path]).to eq("vector")
    end
  end
end
