# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/mcp/core_tools"

# Specs ciblees sur l'outil MCP `system_doctor` ajoute par
# openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
# (Requirement: MCP Tool Surface).
RSpec.describe "Mcp::CoreTools system_doctor tool" do
  before { Mcp::ToolRegistry.reset! }

  let(:retriever) { instance_double(Agent::HybridRetriever) }
  let(:scope_storage) do
    Class.new do
      def list = []
    end.new
  end

  let(:happy_probes) do
    {
      age_loaded?:           ->(_) { true },
      region:                ->(_) { "eu-west-1" },
      graph_lag_p95:         ->(_) { 30.0 },
      graph_role_can_write?: ->(_) { false }
    }
  end

  it "system_doctor est enregistre avec le scope read:health et zero parametre" do
    Mcp::CoreTools.register_all!(
      retriever: retriever,
      scope_storage: scope_storage
    )
    tool = Mcp::ToolRegistry.fetch("system_doctor")
    expect(tool.scopes).to eq([:"read:health"])
    expect(tool.params_schema).to eq({})
  end

  it "retourne le rapport Reconaut::Doctor en Hash serialisable" do
    Mcp::CoreTools.register_all!(
      retriever:     retriever,
      scope_storage: scope_storage,
      doctor_probes: happy_probes,
      doctor_env:    { "RECONAUT_EMBEDDER_PROVIDER" => "local" }
    )
    tool = Mcp::ToolRegistry.fetch("system_doctor")

    result = tool.call(
      params: {},
      caller_id: "u-1",
      caller_scopes: [:"read:health"]
    )

    expect(result).to be_a(Hash)
    expect(result.keys).to contain_exactly(:ok, :checks)
    expect(result[:ok]).to be true
    statuses = result[:checks].to_h { |c| [c[:name], c[:status]] }
    expect(statuses["graph_tier"]).to eq(:ok)
    expect(statuses["region"]).to eq(:ok)
  end

  it "remonte un :fail dans checks quand la region est hors EU" do
    bad_probes = happy_probes.merge(region: ->(_) { "us-east-1" })
    Mcp::CoreTools.register_all!(
      retriever:     retriever,
      scope_storage: scope_storage,
      doctor_probes: bad_probes,
      doctor_env:    {}
    )
    tool = Mcp::ToolRegistry.fetch("system_doctor")

    result = tool.call(
      params: {},
      caller_id: "u-1",
      caller_scopes: [:"read:health"]
    )

    expect(result[:ok]).to be false
    region_check = result[:checks].find { |c| c[:name] == "region" }
    expect(region_check[:status]).to eq(:fail)
    expect(region_check[:details]).to include("graph-region-not-allowed")
  end

  it "rejette l'appel sans le scope read:health" do
    Mcp::CoreTools.register_all!(
      retriever: retriever,
      scope_storage: scope_storage,
      doctor_probes: happy_probes
    )
    tool = Mcp::ToolRegistry.fetch("system_doctor")

    expect {
      tool.call(
        params: {},
        caller_id: "u-1",
        caller_scopes: [:"read:hosts"] # pas read:health
      )
    }.to raise_error(Mcp::ScopeError, /read:health/)
  end

  it "permet d'injecter un doctor stub pour les tests sans Reconaut::Doctor reel" do
    fake_doctor = Class.new do
      def self.run(probes:, env:)
        Struct.new(:ok, :checks).new(true, [
          Struct.new(:name, :status, :details).new("custom", :ok, "stubbed").tap do |c|
            c.define_singleton_method(:to_h) { { name: name, status: status, details: details } }
          end
        ]).tap do |r|
          r.define_singleton_method(:to_h) { { ok: ok, checks: checks.map(&:to_h) } }
        end
      end
    end

    Mcp::CoreTools.register_all!(
      retriever:     retriever,
      scope_storage: scope_storage,
      doctor:        fake_doctor
    )
    result = Mcp::ToolRegistry.fetch("system_doctor").call(
      params: {},
      caller_id: "u-1",
      caller_scopes: [:"read:health"]
    )
    expect(result).to eq(ok: true, checks: [{ name: "custom", status: :ok, details: "stubbed" }])
  end
end
