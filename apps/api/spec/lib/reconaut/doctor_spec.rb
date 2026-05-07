# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/reconaut/doctor"

RSpec.describe Reconaut::Doctor do
  def probes(overrides = {})
    {
      age_loaded?:           ->(_) { true },
      region:                ->(_) { "eu-west-1" },
      graph_lag_p95:         ->(_) { 30.0 },
      graph_role_can_write?: ->(_) { false }
    }.merge(overrides)
  end

  it "happy path : tous les checks ok, exit 0" do
    report = described_class.run(probes: probes, env: { "RECONAUT_EMBEDDER_PROVIDER" => "local" })
    expect(report.ok).to be true
    expect(report.exit_code).to eq(0)
    statuses = report.checks.to_h { |c| [c.name, c.status] }
    expect(statuses["graph_tier"]).to eq(:ok)
    expect(statuses["region"]).to eq(:ok)
    expect(statuses["graph_lag"]).to eq(:ok)
    expect(statuses["graph_role_reader"]).to eq(:ok)
    expect(statuses["external_llm_required"]).to eq(:ok)
  end

  it "AGE non chargee -> graph_tier fail + exit 1" do
    report = described_class.run(
      probes: probes(age_loaded?: ->(_) { false }),
      env: { "RECONAUT_EMBEDDER_PROVIDER" => "local" }
    )
    expect(report.ok).to be false
    expect(report.exit_code).to eq(1)
    fail_check = report.checks.find { |c| c.name == "graph_tier" }
    expect(fail_check.status).to eq(:fail)
    expect(fail_check.details).to include("graph-extension-missing")
  end

  it "region non-EU -> graph-region-not-allowed + exit 1" do
    report = described_class.run(
      probes: probes(region: ->(_) { "us-east-1" }),
      env: {}
    )
    expect(report.ok).to be false
    region_check = report.checks.find { |c| c.name == "region" }
    expect(region_check.status).to eq(:fail)
    expect(region_check.details).to include("graph-region-not-allowed")
    expect(region_check.details).to include("us-east-1")
  end

  it "region absente -> graph-region-unknown" do
    report = described_class.run(
      probes: probes(region: ->(_) { nil }),
      env: {}
    )
    expect(report.ok).to be false
    region_check = report.checks.find { |c| c.name == "region" }
    expect(region_check.details).to include("graph-region-unknown")
  end

  it "graph_lag p95 > 60s -> fail" do
    report = described_class.run(
      probes: probes(graph_lag_p95: ->(_) { 120.0 }),
      env: {}
    )
    expect(report.ok).to be false
    lag = report.checks.find { |c| c.name == "graph_lag" }
    expect(lag.status).to eq(:fail)
    expect(lag.details).to include("graph-lag-too-high")
  end

  it "graph_lag inconnu -> :unknown sans fail global (warn seulement)" do
    report = described_class.run(
      probes: probes(graph_lag_p95: ->(_) { nil }),
      env: {}
    )
    lag = report.checks.find { |c| c.name == "graph_lag" }
    expect(lag.status).to eq(:unknown)
    # :unknown ne casse pas le ok global puisque ce n'est pas un :fail.
    expect(report.ok).to be true
  end

  it "reader peut ecrire -> graph-reader-can-write fail" do
    report = described_class.run(
      probes: probes(graph_role_can_write?: ->(_) { true }),
      env: {}
    )
    role_check = report.checks.find { |c| c.name == "graph_role_reader" }
    expect(role_check.status).to eq(:fail)
    expect(role_check.details).to include("graph-reader-can-write")
  end

  it "external_llm_required = ok quand provider=local" do
    report = described_class.run(probes: probes, env: { "RECONAUT_EMBEDDER_PROVIDER" => "local" })
    llm = report.checks.find { |c| c.name == "external_llm_required" }
    expect(llm.status).to eq(:ok)
    expect(llm.details).to include("auto-suffisante")
  end

  it "external_llm_required = info (pas fail) quand provider=mistral" do
    report = described_class.run(probes: probes, env: { "RECONAUT_EMBEDDER_PROVIDER" => "mistral" })
    llm = report.checks.find { |c| c.name == "external_llm_required" }
    expect(llm.status).to eq(:info)
    expect(llm.details).to include("mistral")
  end

  it "report.to_h serialise pour JSON" do
    report = described_class.run(probes: probes, env: {})
    h = report.to_h
    expect(h.keys).to contain_exactly(:ok, :checks)
    expect(h[:checks]).to all(include(:name, :status, :details))
  end

  it "default fail closed : sans probes, AGE = absent + reader = peut ecrire" do
    report = described_class.run(probes: {}, env: {})
    expect(report.ok).to be false
    statuses = report.checks.to_h { |c| [c.name, c.status] }
    expect(statuses["graph_tier"]).to eq(:fail)
    expect(statuses["graph_role_reader"]).to eq(:fail)
  end
end
