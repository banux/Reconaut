# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-embedding-pipeline/specs/agent-interface/spec.md
#   -> Requirement: VectorRetriever Backed by pgvector

RSpec.describe Agent::VectorRetriever do
  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.connection.execute("SELECT 1")
      unless ActiveRecord::Base.connection.table_exists?("embeddings")
        @skip = "Table embeddings absente — RAILS_ENV=test bundle exec rails db:migrate"
      end
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before(:each) do
    skip(@skip) if @skip
    Service.delete_all if defined?(Service) && Service.table_exists?
    Embedding.delete_all
    Host.delete_all
  end

  let(:embedder) do
    Class.new {
      def embed(texts:) = texts.map { |_| Array.new(384, 0.5) }
      def dim     = 384
      def provider = "local"
    }.new
  end

  describe "#call" do
    it "table vide → retourne []" do
      r = described_class.new(embedder: embedder).call("modbus")
      expect(r).to eq([])
    end

    it "table peuplée → retourne host_id + scanned_at pour chaque ligne" do
      hosts = 3.times.map do |i|
        h = Host.create!(ip: "192.0.2.#{i + 10}")
        Reconaut::EmbeddingIndexer.index!(h, embedder: embedder)
        h
      end

      rows = described_class.new(embedder: embedder).call("anything")
      expect(rows.size).to eq(3)
      expect(rows.map { |r| r["host_id"] }).to match_array(hosts.map(&:id))
      rows.each do |r|
        expect(r["scanned_at"]).to be_a(String).and(match(/\A\d{4}-\d{2}-\d{2}T/))
      end
    end

    it "limit respecté" do
      6.times do |i|
        h = Host.create!(ip: "192.0.2.#{i + 20}")
        Reconaut::EmbeddingIndexer.index!(h, embedder: embedder)
      end

      r = described_class.new(embedder: embedder, limit: 3).call("x")
      expect(r.size).to eq(3)
    end

    it "embedder UnavailableError → propagée (mapping 503 en amont)" do
      bad = Class.new {
        def embed(texts:) = raise Reconaut::Embedder::UnavailableError, "down"
      }.new
      expect { described_class.new(embedder: bad).call("x") }
        .to raise_error(Reconaut::Embedder::UnavailableError)
    end

    it "embedder TimeoutError → propagé" do
      bad = Class.new {
        def embed(texts:) = raise Reconaut::Embedder::TimeoutError, "slow"
      }.new
      expect { described_class.new(embedder: bad).call("x") }
        .to raise_error(Reconaut::Embedder::TimeoutError)
    end

    it "erreur SQL (pgvector indisponible, dim mismatch) → retourne [] gracieusement" do
      broken = Class.new {
        # Retourne un vecteur de dim 100 incompatible avec vector(384)
        def embed(texts:) = texts.map { |_| Array.new(100, 0.0) }
        def dim     = 100
        def provider = "broken"
      }.new
      rows = described_class.new(embedder: broken).call("x")
      expect(rows).to eq([])
    end
  end
end
