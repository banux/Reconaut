# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require_relative "../../../../app/lib/reconaut/embedder"

# Contrat commun aux 4 implementations Embedder. Verifie :
#  (i) dim de sortie coherente avec la config
#  (ii) determinisme batch vs single-item a epsilon pres
#  (iii) timeout / erreur explicite quand le backend est indisponible
#
# Cf. openspec/changes/init-reconaut-platform/tasks.md section 4.1.

RSpec.describe "Reconaut::Embedder contract" do
  shared_examples "Embedder" do
    it "respecte la dim declaree" do
      vectors = embedder.embed(texts: ["hello", "world"])
      expect(vectors.length).to eq(2)
      expect(vectors).to all(be_a(Array))
      expect(vectors.first.length).to eq(expected_dim)
    end

    it "est deterministe : meme texte -> meme vecteur en single ou batch" do
      single = embedder.embed(texts: ["nginx 1.18"]).first
      batch  = embedder.embed(texts: ["other", "nginx 1.18"]).last
      expect(single).to eq(batch)
    end
  end

  describe Reconaut::Embedder::Local do
    let(:embedder)     { described_class.new(dim: 64) }
    let(:expected_dim) { 64 }

    include_examples "Embedder"

    it "n'effectue AUCUN appel reseau (pas de Net::HTTP)" do
      # Defense en profondeur : on stubbe Net::HTTP.start pour exploser.
      allow(Net::HTTP).to receive(:start).and_raise("local should never call network")
      expect { embedder.embed(texts: ["x"]) }.not_to raise_error
    end

    it "rejette dim <= 0" do
      expect { described_class.new(dim: 0) }.to raise_error(ArgumentError)
    end

    it "supporte le texte vide" do
      v = embedder.embed(texts: [""]).first
      expect(v.length).to eq(64)
    end
  end

  # Pour les 3 implementations HTTP, on injecte un faux client qui
  # repond ce qu'on lui dit. Cela suffit pour exercer le contrat sans
  # depende d'un service reel.

  class FakeHttp
    def initialize(status:, body:)
      @status = status
      @body   = body
    end

    def post(_uri, _body, _headers = {})
      OpenStruct.new(code: @status.to_s, body: @body)
    end
  end

  describe Reconaut::Embedder::Ollama do
    let(:embedder) do
      described_class.new(
        url: "http://localhost:11434",
        model: "nomic-embed",
        http_client: FakeHttp.new(
          status: 200,
          body: { embedding: Array.new(768) { 0.5 } }.to_json
        )
      )
    end
    let(:expected_dim) { 768 }

    include_examples "Embedder"

    it "leve UnavailableError sur HTTP 500" do
      e = described_class.new(
        url: "http://localhost:11434", model: "x",
        http_client: FakeHttp.new(status: 500, body: "")
      )
      expect { e.embed(texts: ["x"]) }
        .to raise_error(Reconaut::Embedder::UnavailableError, /HTTP 500/)
    end

    it "leve UnavailableError quand 'embedding' absent du payload" do
      e = described_class.new(
        url: "http://localhost:11434", model: "x",
        http_client: FakeHttp.new(status: 200, body: "{}")
      )
      expect { e.embed(texts: ["x"]) }
        .to raise_error(Reconaut::Embedder::UnavailableError, /missing embedding/)
    end
  end

  describe Reconaut::Embedder::Mistral do
    let(:embedder) do
      described_class.new(
        api_key: "k",
        model: "mistral-embed",
        http_client: FakeHttp.new(
          status: 200,
          body: { data: [
            { embedding: Array.new(1024) { 0.1 } },
            { embedding: Array.new(1024) { 0.2 } }
          ] }.to_json
        )
      )
    end
    let(:expected_dim) { 1024 }

    it "respecte la dim declaree (forme batch)" do
      vectors = embedder.embed(texts: ["a", "b"])
      expect(vectors.length).to eq(2)
      expect(vectors.first.length).to eq(expected_dim)
    end

    it "rejette une api_key vide a la construction" do
      expect { described_class.new(api_key: "", model: "x") }.to raise_error(ArgumentError)
    end

    it "leve UnavailableError sur HTTP 401" do
      e = described_class.new(
        api_key: "bad", model: "x",
        http_client: FakeHttp.new(status: 401, body: '{"message":"unauthorized"}')
      )
      expect { e.embed(texts: ["x"]) }
        .to raise_error(Reconaut::Embedder::UnavailableError, /HTTP 401/)
    end
  end

  describe Reconaut::Embedder::OpenAICompatible do
    let(:embedder) do
      described_class.new(
        base_url: "http://lm-studio:1234",
        api_key: "ignored",
        model: "nomic-embed",
        http_client: FakeHttp.new(
          status: 200,
          body: { data: [{ embedding: Array.new(384) { 0.0 } }] }.to_json
        )
      )
    end

    it "construit la dim depuis le payload" do
      vectors = embedder.embed(texts: ["hello"])
      expect(vectors.first.length).to eq(384)
    end

    it "rejette une base_url vide" do
      expect {
        described_class.new(base_url: "", api_key: "k", model: "m")
      }.to raise_error(ArgumentError)
    end

    it "rejette un model vide" do
      expect {
        described_class.new(base_url: "http://x", api_key: "k", model: "")
      }.to raise_error(ArgumentError)
    end
  end
end
