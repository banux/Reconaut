# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-embedder-pluggable/specs/agent-interface/spec.md
#   -> Requirement: Boot Validation of Embedder Configuration
#
# Le test direct du boot Rails (RAILS_ENV=production) en spawn de
# Process est lourd (charge Bundler, Rails, DB). On valide le contrat
# en deux temps :
#   1. Le fichier d'initializer existe et appelle Embedder.build.
#   2. Embedder.build elle-même lève MisconfiguredError quand la config
#      est invalide — comportement fondamental couvert par build_spec.
#
# Le test e2e du Process spawn vit dans spec/integration (cf. §7.3).

RSpec.describe "embedder_validation initializer" do
  let(:initializer_path) do
    Rails.root.join("config/initializers/embedder_validation.rb")
  end

  it "le fichier d'initializer existe" do
    expect(File.exist?(initializer_path)).to be true
  end

  it "appelle Reconaut::Embedder.build au boot" do
    src = File.read(initializer_path)
    expect(src).to include("Reconaut::Embedder.build(env: ENV)")
    expect(src).to include("MisconfiguredError")
    expect(src).to include("abort")
  end

  it "skippe en environnement test (les specs injectent leur propre embedder)" do
    src = File.read(initializer_path)
    expect(src).to match(/return if Rails\.env\.test\?/)
  end

  it "Embedder.build lève MisconfiguredError sur ollama sans URL (boot fail-fast)" do
    expect {
      Reconaut::Embedder.build(env: { "RECONAUT_EMBEDDER_PROVIDER" => "ollama" })
    }.to raise_error(Reconaut::Embedder::MisconfiguredError, /url/)
  end

  it "Embedder.build lève MisconfiguredError sur mistral sans clé (boot fail-fast)" do
    expect {
      Reconaut::Embedder.build(env: { "RECONAUT_EMBEDDER_PROVIDER" => "mistral" })
    }.to raise_error(Reconaut::Embedder::MisconfiguredError, /api_key/)
  end

  it "Embedder.build sur local par défaut → succès, log [embedder] provider=local dim=384" do
    embedder = Reconaut::Embedder.build(env: {})
    expect(embedder.provider).to eq("local")
    expect(embedder.dim).to eq(384)
  end
end
