# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/mcp/tool_registry"

RSpec.describe Mcp::ToolRegistry do
  before { described_class.reset! }

  it "register + fetch + names + all" do
    described_class.register(
      name: "echo",
      scopes: [:"read:hosts"],
      params_schema: { msg: { type: :string, min_length: 1, max_length: 100 } }
    ) { |params:, caller_id:| { echoed: params[:msg], by: caller_id } }

    expect(described_class.names).to eq(["echo"])
    tool = described_class.fetch("echo")
    expect(tool.scopes).to eq([:"read:hosts"])
  end

  it "fetch leve UnknownToolError sur outil inconnu" do
    expect { described_class.fetch("nope") }
      .to raise_error(Mcp::UnknownToolError)
  end

  it "register sans handler -> ArgumentError" do
    expect {
      described_class.register(name: "x", scopes: [], params_schema: {})
    }.to raise_error(ArgumentError, /handler/)
  end

  describe "#call sur Tool" do
    let(:tool) do
      described_class.register(
        name: "echo",
        scopes: [:"read:hosts"],
        params_schema: { msg: { type: :string, min_length: 1, max_length: 100 } }
      ) { |params:, caller_id:| { echoed: params[:msg], by: caller_id } }
      described_class.fetch("echo")
    end

    it "execute le handler avec les params coerces" do
      result = tool.call(
        params: { msg: "hi" },
        caller_id: "u-1",
        caller_scopes: [:"read:hosts"]
      )
      expect(result).to eq(echoed: "hi", by: "u-1")
    end

    it "rejette si scope manquant -> ScopeError" do
      expect {
        tool.call(params: { msg: "hi" }, caller_id: "u", caller_scopes: [])
      }.to raise_error(Mcp::ScopeError, /missing scopes/)
    end

    it "rejette si parametre requis manquant" do
      expect {
        tool.call(params: {}, caller_id: "u", caller_scopes: [:"read:hosts"])
      }.to raise_error(Mcp::MissingParamError, /msg/)
    end

    it "rejette si type incorrect" do
      expect {
        tool.call(params: { msg: 123 }, caller_id: "u", caller_scopes: [:"read:hosts"])
      }.to raise_error(Mcp::ParamTypeError, /msg/)
    end

    it "rejette si plage hors bornes" do
      expect {
        tool.call(params: { msg: "" }, caller_id: "u", caller_scopes: [:"read:hosts"])
      }.to raise_error(Mcp::ParamOutOfRangeError, /shorter/)
    end
  end

  describe "coerce_params" do
    it "applique le default sur required: false" do
      schema = { limit: { type: :integer, required: false, default: 50, min: 1, max: 100 } }
      coerced = described_class.coerce_params(schema, {})
      expect(coerced[:limit]).to eq(50)
    end

    it "valide min/max sur integer" do
      schema = { n: { type: :integer, min: 1, max: 10 } }
      expect { described_class.coerce_params(schema, n: 0) }
        .to raise_error(Mcp::ParamOutOfRangeError, /below min/)
      expect { described_class.coerce_params(schema, n: 100) }
        .to raise_error(Mcp::ParamOutOfRangeError, /above max/)
      expect(described_class.coerce_params(schema, n: 5)).to eq(n: 5)
    end

    it "valide enum" do
      schema = { kind: { type: :enum, values: %w[a b c] } }
      expect { described_class.coerce_params(schema, kind: "z") }
        .to raise_error(Mcp::ParamOutOfRangeError, /enum/)
      expect(described_class.coerce_params(schema, kind: "b")).to eq(kind: "b")
    end
  end
end
