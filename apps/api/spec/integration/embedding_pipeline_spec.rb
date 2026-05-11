# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-embedding-pipeline/specs/agent-interface/spec.md
#
# Test e2e du pipeline complet : création d'host → IndexHostJob →
# ligne dans embeddings → VectorRetriever retourne le host via
# `agent_chat` MCP.

RSpec.describe "Embedding pipeline e2e", type: :request do
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
    ActiveJob::Base.queue_adapter = :test
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

  describe "(a) création de host enqueue un IndexHostJob" do
    it "Host.create! enqueue IndexHostJob avec host.id" do
      expect {
        Host.create!(ip: "192.0.2.100")
      }.to have_enqueued_job(IndexHostJob)
    end
  end

  describe "(b) exécution synchrone du job → ligne embeddings" do
    it "perform_now insère une ligne avec le host_id" do
      host = Host.create!(ip: "192.0.2.101")
      allow(Reconaut::Registry.default).to receive(:embedder).and_return(embedder)

      IndexHostJob.new.perform(host.id)

      expect(Embedding.where(host_id: host.id).count).to eq(1)
      expect(Embedding.last.content).to include("192.0.2.101")
    end
  end

  describe "(c) recherche via VectorRetriever après indexation" do
    it "VectorRetriever retourne le host indexé" do
      host = Host.create!(ip: "192.0.2.102")
      Reconaut::EmbeddingIndexer.index!(host, embedder: embedder)

      retriever = Agent::VectorRetriever.new(embedder: embedder)
      rows = retriever.call("anything")
      expect(rows.map { |r| r["host_id"] }).to include(host.id)
    end
  end

  describe "(d) re-indexation après update de fqdn" do
    it "update fqdn → ligne embeddings reflète le nouveau fingerprint" do
      host = Host.create!(ip: "192.0.2.103")
      Reconaut::EmbeddingIndexer.index!(host, embedder: embedder)
      first = Embedding.find_by(host_id: host.id)
      first_content = first.content

      host.update!(fqdn: "new.example.fr")
      Reconaut::EmbeddingIndexer.index!(host.reload, embedder: embedder)

      reloaded = Embedding.find_by(host_id: host.id)
      expect(reloaded.id).to eq(first.id) # upsert
      expect(reloaded.content).to include("new.example.fr")
      expect(reloaded.content).not_to eq(first_content)
    end
  end

  describe "(e) host supprimé entre enqueue et job → no-op gracieux" do
    it "IndexHostJob.perform avec un host_id inexistant ne crash pas" do
      expect {
        IndexHostJob.new.perform("00000000-0000-0000-0000-000000000000")
      }.not_to raise_error
      expect(Embedding.count).to eq(0)
    end
  end

  describe "(f) Pipeline.build construit un retriever fonctionnel" do
    it "le retriever construit retourne les rows indexées" do
      host = Host.create!(ip: "192.0.2.104")
      Reconaut::EmbeddingIndexer.index!(host, embedder: embedder)

      reg = Reconaut::Registry.new
      reg.embedder = embedder
      retriever = Reconaut::Agent::Pipeline.build(registry: reg)
      response = retriever.call("anything")
      expect(response.rows.map { |r| r["host_id"] || r[:host_id] }).to include(host.id)
    end
  end
end
