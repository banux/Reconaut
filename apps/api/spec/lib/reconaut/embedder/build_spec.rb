# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../app/lib/reconaut/embedder"

# Validation au boot via Reconaut::Embedder.build(env: { ... }).
# Cf. openspec/changes/init-reconaut-platform/tasks.md section 4.2.

RSpec.describe Reconaut::Embedder, ".build" do
  it "defaut sans variable -> Local" do
    embedder = described_class.build(env: {})
    expect(embedder).to be_a(Reconaut::Embedder::Local)
    expect(embedder.dim).to eq(Reconaut::Embedder::DEFAULT_LOCAL_DIM)
  end

  it "RECONAUT_EMBEDDER_PROVIDER=local + LOCAL_DIM custom" do
    embedder = described_class.build(env: {
      "RECONAUT_EMBEDDER_PROVIDER" => "local",
      "RECONAUT_EMBEDDER_LOCAL_DIM" => "128"
    })
    expect(embedder.dim).to eq(128)
  end

  it "ollama sans URL -> embedder-misconfigured" do
    expect {
      described_class.build(env: { "RECONAUT_EMBEDDER_PROVIDER" => "ollama" })
    }.to raise_error(Reconaut::Embedder::MisconfiguredError, /url/)
  end

  it "ollama avec URL et MODEL ok" do
    embedder = described_class.build(env: {
      "RECONAUT_EMBEDDER_PROVIDER" => "ollama",
      "RECONAUT_EMBEDDER_OLLAMA_URL" => "http://localhost:11434",
      "RECONAUT_EMBEDDER_OLLAMA_MODEL" => "nomic-embed"
    })
    expect(embedder).to be_a(Reconaut::Embedder::Ollama)
    expect(embedder.model).to eq("nomic-embed")
  end

  it "mistral sans cle -> embedder-misconfigured" do
    expect {
      described_class.build(env: { "RECONAUT_EMBEDDER_PROVIDER" => "mistral" })
    }.to raise_error(Reconaut::Embedder::MisconfiguredError, /api_key/)
  end

  it "mistral avec cle ok" do
    embedder = described_class.build(env: {
      "RECONAUT_EMBEDDER_PROVIDER" => "mistral",
      "RECONAUT_EMBEDDER_MISTRAL_API_KEY" => "k"
    })
    expect(embedder).to be_a(Reconaut::Embedder::Mistral)
  end

  it "openai-compatible sans BASE_URL -> embedder-misconfigured" do
    expect {
      described_class.build(env: {
        "RECONAUT_EMBEDDER_PROVIDER" => "openai-compatible",
        "RECONAUT_EMBEDDER_OPENAI_API_KEY" => "k",
        "RECONAUT_EMBEDDER_OPENAI_MODEL" => "m"
      })
    }.to raise_error(Reconaut::Embedder::MisconfiguredError, /base_url/)
  end

  it "openai-compatible avec BASE_URL + API_KEY + MODEL ok" do
    embedder = described_class.build(env: {
      "RECONAUT_EMBEDDER_PROVIDER" => "openai-compatible",
      "RECONAUT_EMBEDDER_OPENAI_BASE_URL" => "http://lm:1234",
      "RECONAUT_EMBEDDER_OPENAI_API_KEY" => "k",
      "RECONAUT_EMBEDDER_OPENAI_MODEL" => "nomic"
    })
    expect(embedder).to be_a(Reconaut::Embedder::OpenAICompatible)
  end

  it "provider inconnu -> embedder-misconfigured" do
    expect {
      described_class.build(env: { "RECONAUT_EMBEDDER_PROVIDER" => "openai" })
    }.to raise_error(Reconaut::Embedder::MisconfiguredError, /unknown provider/)
  end
end
