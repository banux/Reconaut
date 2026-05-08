# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/use_cases/agent/handle_query"
require_relative "../../../app/lib/agent/audit_recorder"

# En mode mono-user (cf. openspec/changes/single-user-only/), le use
# case ne porte plus de contrôle de rôle — l'autorisation se fait via
# le scope MCP `agent:chat` au niveau du tool.
RSpec.describe Agent::UseCases::HandleQuery do
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

  describe "validation" do
    it "rejette une query vide avec 400" do
      result = use_case.call(query: "  ")
      expect(result.status).to eq(:bad_request)
      expect(result.body[:error]).to eq("query_required")
    end

    it "rejette une query nil avec 400" do
      result = use_case.call(query: nil)
      expect(result.status).to eq(:bad_request)
    end
  end

  describe "shape de la réponse OK" do
    it "renvoie le contrat rows/citations/warnings/retrieval_path/duration_ms" do
      result = use_case.call(query: "hotes nginx")
      body = result.body

      expect(body.keys).to contain_exactly(
        :rows, :citations, :warnings, :retrieval_path, :duration_ms
      )
      expect(body[:rows]).to eq(rows)
      expect(body[:retrieval_path]).to eq("graph")
      expect(body[:duration_ms]).to eq(30)
      expect(body[:citations]).to all(be_a(Hash))
      expect(body[:citations].first[:host_id]).to eq("h1")
    end
  end

  describe "audit" do
    it "écrit une ligne d'audit success en cas de succès" do
      use_case.call(query: "x", caller_id: "key:abc")
      entry = audit.entries.last
      expect(entry[:status]).to eq(:success)
      expect(entry[:caller_id]).to eq("key:abc")
      expect(entry[:nodes_touched]).to eq(rows.size)
      expect(entry[:duration_ms]).to eq(30)
    end

    it "écrit une ligne d'audit param_invalid sur query vide" do
      use_case.call(query: "")
      expect(audit.entries.last[:status]).to eq(:param_invalid)
    end

    it "ne fait JAMAIS échouer la requête si l'audit lève" do
      broken_audit = Object.new
      def broken_audit.record(*) = raise "audit DB down"

      uc = described_class.new(retriever: retriever, audit_recorder: broken_audit)
      expect { uc.call(query: "x") }.not_to raise_error
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
      result = uc.call(query: "x")
      expect(result.body[:warnings]).to eq(["graph_unavailable"])
      expect(result.body[:retrieval_path]).to eq("vector")
    end
  end
end
