# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-embedder-pluggable/specs/agent-interface/spec.md
#   -> Requirement: Embedder Resilience

RSpec.describe Reconaut::Embedder::Resilient do
  # Embedder factice contrôlable en test : suit la séquence d'erreurs
  # programmée, sinon retourne un vecteur de zeros.
  class FakeInner
    attr_reader :calls
    def initialize(behavior: ->(_) { [Array.new(384, 0.0)] })
      @behavior = behavior
      @calls = 0
    end
    def embed(texts:)
      @calls += 1
      @behavior.call(texts)
    end
    def dim = 384
    def provider = "fake"
  end

  let(:inner) { FakeInner.new }
  subject(:resilient) do
    described_class.new(inner,
      timeout_s: 0.5,
      breaker_failures: 3,
      breaker_window_s: 10,
      breaker_open_s: 1
    )
  end

  describe "interface substituable" do
    it "expose dim et provider de l'inner" do
      expect(resilient.dim).to eq(384)
      expect(resilient.provider).to eq("fake")
    end

    it "embed passe-plat en cas de succès" do
      r = resilient.embed(texts: ["hello"])
      expect(r).to eq([Array.new(384, 0.0)])
      expect(inner.calls).to eq(1)
    end
  end

  describe "timeout" do
    let(:inner) do
      FakeInner.new(behavior: ->(_) { sleep 1.5; [[]] })
    end

    it "lève TimeoutError au-delà de timeout_s" do
      start = Time.now
      expect { resilient.embed(texts: ["x"]) }.to raise_error(Reconaut::Embedder::TimeoutError)
      elapsed = Time.now - start
      expect(elapsed).to be < 1.0 # bien en deçà du sleep 1.5s
    end

    it "incrémente failures_total après timeout" do
      expect { resilient.embed(texts: ["x"]) }.to raise_error(Reconaut::Embedder::TimeoutError)
      expect(resilient.stats[:failures_total]).to eq(1)
      expect(resilient.stats[:last_error]).to eq("timeout")
    end
  end

  describe "UnavailableError propagation" do
    let(:inner) do
      FakeInner.new(behavior: ->(_) { raise Reconaut::Embedder::UnavailableError, "backend down" })
    end

    it "propage UnavailableError et incrémente failures_total" do
      expect { resilient.embed(texts: ["x"]) }
        .to raise_error(Reconaut::Embedder::UnavailableError)
      expect(resilient.stats[:failures_total]).to eq(1)
      expect(resilient.stats[:last_error]).to include("backend down")
    end
  end

  describe "circuit breaker" do
    let(:inner) do
      FakeInner.new(behavior: ->(_) { raise Reconaut::Embedder::UnavailableError, "down" })
    end

    it "ouvre après N échecs et lève CircuitOpenError immédiatement" do
      3.times do
        expect { resilient.embed(texts: ["x"]) }.to raise_error(Reconaut::Embedder::UnavailableError)
      end
      # 4ème appel : circuit ouvert
      expect(resilient.stats[:circuit_state]).to eq(:open)

      # Le backend ne doit plus être touché.
      calls_before = inner.calls
      expect { resilient.embed(texts: ["x"]) }.to raise_error(Reconaut::Embedder::CircuitOpenError)
      expect(inner.calls).to eq(calls_before)
    end

    it "passe à :half_open après open_s puis :closed sur succès" do
      3.times do
        expect { resilient.embed(texts: ["x"]) }.to raise_error(Reconaut::Embedder::UnavailableError)
      end
      expect(resilient.stats[:circuit_state]).to eq(:open)

      sleep 1.1 # > open_s = 1

      expect(resilient.stats[:circuit_state]).to eq(:half_open)

      # Bascule l'inner vers succès
      inner.instance_variable_set(:@behavior, ->(_) { [Array.new(384, 0.0)] })
      r = resilient.embed(texts: ["x"])
      expect(r).to be_an(Array)
      expect(resilient.stats[:circuit_state]).to eq(:closed)
    end

    it "ré-ouvre si half_open échoue" do
      3.times do
        expect { resilient.embed(texts: ["x"]) }.to raise_error(Reconaut::Embedder::UnavailableError)
      end
      sleep 1.1
      expect(resilient.stats[:circuit_state]).to eq(:half_open)
      expect { resilient.embed(texts: ["x"]) }.to raise_error(Reconaut::Embedder::UnavailableError)
      expect(resilient.stats[:circuit_state]).to eq(:open)
    end
  end

  describe "stats" do
    it "expose les 5 clefs documentées" do
      keys = resilient.stats.keys.sort
      expect(keys).to eq(%i[circuit_state dim failures_total last_error provider].sort)
    end
  end
end
