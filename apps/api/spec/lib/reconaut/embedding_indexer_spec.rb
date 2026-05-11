# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-embedding-pipeline/specs/agent-interface/spec.md
#   -> Requirement: Host Indexing Pipeline

RSpec.describe Reconaut::EmbeddingIndexer do
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

  let(:host) { Host.create!(ip: "192.0.2.10") }

  describe ".fingerprint_for" do
    it "produit un texte non-vide incluant ip et marqueurs first/last_seen" do
      text = described_class.fingerprint_for(host)
      expect(text).to include("192.0.2.10")
      expect(text).to include("first_seen=")
      expect(text).to include("last_seen=")
    end

    it "intègre les services associés dans l'ordre port/protocol" do
      host
      host.services.create!(host_id: host.id, port: 80, protocol: "tcp", banner: "nginx", scanned_at: Time.now, outcome: "success")
      host.services.create!(host_id: host.id, port: 22, protocol: "tcp", banner: "SSH-2.0", scanned_at: Time.now, outcome: "success")
      text = described_class.fingerprint_for(host.reload)
      expect(text).to include("port=22")
      expect(text).to include("port=80")
      # Ordre par port croissant
      expect(text.index("port=22")).to be < text.index("port=80")
    end

    it "déterministe : mêmes inputs → même texte" do
      a = described_class.fingerprint_for(host)
      b = described_class.fingerprint_for(host.reload)
      expect(a).to eq(b)
    end
  end

  describe ".index!" do
    it "insère une ligne avec content non-vide, vector(384), provider/dim/model populés" do
      row = described_class.index!(host, embedder: embedder)
      expect(Embedding.count).to eq(1)
      expect(row.content).to include("192.0.2.10")
      expect(row.provider).to eq("local")
      expect(row.dim).to eq(384)
      expect(row.model).to eq("stub-384")
    end

    it "upsert : appel répété sur le même host → count reste à 1" do
      described_class.index!(host, embedder: embedder)
      described_class.index!(host, embedder: embedder)
      expect(Embedding.count).to eq(1)
    end

    it "embedder qui lève UnavailableError → l'erreur remonte" do
      bad = Class.new {
        def embed(texts:) = raise Reconaut::Embedder::UnavailableError, "down"
        def dim = 384
        def provider = "mistral"
      }.new
      expect { described_class.index!(host, embedder: bad) }
        .to raise_error(Reconaut::Embedder::UnavailableError)
      expect(Embedding.count).to eq(0)
    end

    it "second indexation après update modifie le content + indexed_at" do
      r1 = described_class.index!(host, embedder: embedder)
      first_at = r1.indexed_at
      sleep 0.01

      host.update!(fqdn: "host.example.fr")
      r2 = described_class.index!(host.reload, embedder: embedder)
      expect(r2.id).to eq(r1.id)
      expect(r2.content).to include("host.example.fr")
      expect(r2.indexed_at).to be > first_at
    end
  end

  describe ".pg_vector_literal" do
    it "produit un littéral pgvector [..,..,..]" do
      lit = described_class.pg_vector_literal([0.1, 0.2, 0.3])
      expect(lit).to eq("[0.1,0.2,0.3]")
    end
  end
end
