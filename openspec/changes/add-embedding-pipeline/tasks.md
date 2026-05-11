# Tâches : add-embedding-pipeline

Checklist de la livraison du pipeline d'indexation + câblage du retriever vectoriel réel dans le `Registry`.

---

## 1. Service d'indexation

- [x] **1.1 `Reconaut::EmbeddingIndexer`**
  - **Notes** : Nouveau service `apps/api/app/lib/reconaut/embedding_indexer.rb` :
    ```ruby
    module Reconaut
      class EmbeddingIndexer
        def self.index!(host, embedder: Reconaut::Registry.default.embedder)
          text   = fingerprint_for(host)
          vector = embedder.embed(texts: [text]).first
          provider = embedder.respond_to?(:provider) ? embedder.provider : "unknown"
          dim      = embedder.respond_to?(:dim)      ? embedder.dim      : vector.length
          model    = "stub-#{dim}" # à enrichir quand l'embedder expose .model

          row = Embedding.find_or_initialize_by(host_id: host.id)
          row.assign_attributes(
            content:    text,
            vector:     pg_vector_literal(vector),
            provider:   provider,
            model:      model,
            dim:        dim,
            indexed_at: Time.now.utc
          )
          row.save!
          row
        end

        def self.fingerprint_for(host)
          parts = [host.ip, host.fqdn,
                   "first_seen=#{host.first_seen_at}",
                   "last_seen=#{host.last_seen_at}"]
          host.services.order(:port, :protocol).each do |s|
            parts << "service: port=#{s.port} protocol=#{s.protocol} banner=#{s.banner&.first(200)}"
          end
          parts.compact.join("\n")
        end

        def self.pg_vector_literal(arr)
          "[" + arr.map { |f| f.to_f }.join(",") + "]"
        end
      end
    end
    ```
  - **Test plan** : Spec `embedding_indexer_spec.rb` :
    - (a) `index!(host)` insère une ligne avec content non-vide, vector(384), provider/dim/model populés.
    - (b) Appel répété sur le même host → upsert (count reste à 1), vector mis à jour.
    - (c) Embedder qui lève `UnavailableError` → l'erreur remonte (pour que le job puisse retry).
    - (d) Fingerprint déterministe : mêmes inputs → même text.

- [x] **1.2 `IndexHostJob` GoodJob**
  - **Notes** : `apps/api/app/jobs/index_host_job.rb` :
    ```ruby
    class IndexHostJob < ApplicationJob
      queue_as :default
      retry_on Reconaut::Embedder::UnavailableError, wait: 30.seconds, attempts: 5
      retry_on Reconaut::Embedder::TimeoutError,     wait: 30.seconds, attempts: 3

      def perform(host_id)
        host = Host.find_by(id: host_id)
        return if host.nil? # host supprimé entre enqueue et exécution

        Reconaut::EmbeddingIndexer.index!(host)
      end
    end
    ```
  - **Test plan** : Spec `index_host_job_spec.rb` :
    - (a) `perform(host_id)` invoque l'indexer.
    - (b) `perform("nonexistent-uuid")` retourne sans erreur (host supprimé).
    - (c) `UnavailableError` retry-able (vérifié via `retry_on` config).

- [x] **1.3 Hook AR `Host`**
  - **Notes** : Ajouter dans `apps/api/app/models/host.rb` :
    ```ruby
    after_create_commit  :enqueue_embedding_index!
    after_update_commit  :enqueue_embedding_index!, if: :embedding_relevant_changes?

    EMBEDDING_RELEVANT_COLS = %w[ip fqdn last_seen_at].freeze

    private

    def enqueue_embedding_index!
      ::IndexHostJob.perform_later(id)
    rescue StandardError
      # Si GoodJob n'est pas câblé (specs unitaires), on swallow.
      # Les specs intégrées montent leur propre enqueue.
    end

    def embedding_relevant_changes?
      (saved_changes.keys & EMBEDDING_RELEVANT_COLS).any?
    end
    ```
  - **Test plan** : Spec `host_spec.rb` étendu :
    - (a) `Host.create!(...)` enqueue un `IndexHostJob`.
    - (b) `host.touch` (update sans changement de champ pertinent) → n'enqueue PAS.
    - (c) `host.update!(fqdn: "x")` → enqueue.

---

## 2. Retriever vectoriel + pipeline factory

- [x] **2.1 `Agent::VectorRetriever`**
  - **Notes** : Nouveau fichier `apps/api/app/lib/agent/vector_retriever.rb` :
    ```ruby
    module Agent
      class VectorRetriever
        def initialize(embedder:, limit: 50)
          @embedder = embedder
          @limit    = limit
        end

        def call(query)
          q_vec = @embedder.embed(texts: [query]).first
          literal = "[" + q_vec.map { |f| f.to_f }.join(",") + "]"
          sql = ActiveRecord::Base.sanitize_sql_array([
            "SELECT host_id, indexed_at FROM embeddings ORDER BY vector <=> ?::vector LIMIT ?",
            literal, @limit
          ])
          rows = ActiveRecord::Base.connection.execute(sql).to_a
          rows.map { |r| { "host_id" => r["host_id"], "scanned_at" => r["indexed_at"].to_s } }
        rescue Reconaut::Embedder::UnavailableError,
               Reconaut::Embedder::TimeoutError,
               Reconaut::Embedder::CircuitOpenError
          raise # propage pour que ChatController mappe en 503
        rescue ActiveRecord::ActiveRecordError, PG::Error
          [] # gracieux : table vide ou dim mismatch → 0 row
        end
      end
    end
    ```
  - **Test plan** : Spec `vector_retriever_spec.rb` :
    - (a) Avec 3 lignes en base → retourne 3 rows avec host_id + scanned_at.
    - (b) Table vide → retourne [].
    - (c) `UnavailableError` propagée (pas swallowed).
    - (d) `SQL error` (table absente) → retourne [] gracieusement.

- [x] **2.2 `Reconaut::Agent::Pipeline.build`**
  - **Notes** : Nouveau fichier `apps/api/app/lib/reconaut/agent/pipeline.rb` qui assemble :
    ```ruby
    module Reconaut
      module Agent
        module Pipeline
          module_function

          def build(registry: ::Reconaut::Registry.default)
            ::Agent::HybridRetriever.new(
              router:            VectorOnlyRouter.new,
              template_executor: NullTemplateExecutor.new,
              vector_retriever:  ::Agent::VectorRetriever.new(embedder: registry.embedder)
            )
          end

          class VectorOnlyRouter
            Decision = Struct.new(:semantic_query, keyword_init: true) do
              def graph_path? = false
              def templates  = []
            end

            def decide(query, *)
              Decision.new(semantic_query: query.to_s)
            end
          end

          class NullTemplateExecutor
            Result = Struct.new(:rows, :warning, keyword_init: true) do
              def ok? = true
            end

            def call(_template_id, _params)
              Result.new(rows: [], warning: nil)
            end
          end
        end
      end
    end
    ```
  - **Test plan** : Spec `pipeline_spec.rb` :
    - (a) `Pipeline.build` retourne un `Agent::HybridRetriever`.
    - (b) Le retriever construit avec router VectorOnly + executor Null → mode vector-only fonctionnel.
    - (c) Une query yield les rows du vector_retriever (mocké).

- [x] **2.3 Initializer `agent_pipeline.rb`**
  - **Notes** : `apps/api/config/initializers/agent_pipeline.rb` :
    ```ruby
    Rails.application.config.after_initialize do
      next if Rails.env.test?
      next unless defined?(Reconaut::Agent::Pipeline) && defined?(Embedding)

      if Embedding.table_exists?
        registry = Reconaut::Registry.default
        registry.hybrid_retriever = Reconaut::Agent::Pipeline.build(registry: registry)
        Rails.logger.info "[agent] pipeline wired (provider=#{registry.embedder.provider} dim=#{registry.embedder.dim})"
      else
        Rails.logger.warn "[agent] pipeline not wired (table embeddings absente — exec rails db:migrate)"
      end
    rescue StandardError => e
      Rails.logger.warn "[agent] pipeline not wired : #{e.class}: #{e.message}"
    end
    ```
  - **Test plan** : Smoke test via `bundle exec rails runner 'puts Reconaut::Registry.default.hybrid_retriever.class'` → `Agent::HybridRetriever`.

- [x] **2.4 `mcp_tools.rb` initializer enrichi**
  - **Notes** : Réordonner pour que `agent_pipeline.rb` (qui pose le retriever) tourne AVANT `mcp_tools.rb` (qui le lit). Renommer si nécessaire pour assurer l'ordre alphabétique de chargement, ou utiliser `Rails.application.config.after_initialize` qui garantit l'ordre de déclaration. Vérifier que `mcp_tools.rb` lit bien `registry.hybrid_retriever` mis à jour.
  - **Test plan** : Au boot dev, `Mcp::ToolRegistry.fetch("agent_chat")` invoqué via HTTP retourne des `rows` réels (pas le stub).

---

## 3. Rake task de réindexation

- [x] **3.1 `reconaut:reindex` rake task**
  - **Notes** : Ajouter dans `apps/api/lib/tasks/reconaut.rake` :
    ```ruby
    desc "Re-vectorise tous les hosts existants. RECONAUT_REINDEX_PURGE=true pour vider d'abord, RECONAUT_REINDEX_FILTER='ip:192.0.2.%' pour cibler."
    task reindex: :environment do
      registry = Reconaut::Registry.default
      provider = registry.embedder.provider

      if ENV["RECONAUT_REINDEX_PURGE"].to_s.downcase == "true"
        n = Embedding.where.not(provider: provider).delete_all
        puts "[reindex] purged #{n} legacy embeddings"
      end

      scope = Host.all
      if (f = ENV["RECONAUT_REINDEX_FILTER"]) && f.include?(":")
        col, pattern = f.split(":", 2)
        scope = scope.where("#{col} LIKE ?", pattern) if %w[ip fqdn].include?(col)
      end

      total = scope.count
      done  = 0
      scope.find_each do |h|
        Reconaut::EmbeddingIndexer.index!(h)
        done += 1
        print "\r[reindex] #{done}/#{total}" if (done % 10).zero?
      end
      puts "\n[reindex] done : #{done}/#{total}"
    end
    ```
  - **Test plan** : Spec rake task : avec 3 hosts seedés, `Rake::Task["reconaut:reindex"].execute` produit 3 lignes embeddings. Avec `RECONAUT_REINDEX_PURGE=true` après changement de provider, les anciennes lignes sont purgées.

---

## 4. Doctor enrichi

- [x] **4.1 Check `embedding_pipeline`**
  - **Notes** : Étendre `apps/api/app/lib/reconaut/doctor.rb` avec `check_embedding_pipeline` :
    ```ruby
    def check_embedding_pipeline(_probes, _ctx)
      indexed = Embedding.count
      total   = Host.count
      ratio   = total.zero? ? 1.0 : (indexed.to_f / total).round(2)
      last    = Embedding.maximum(:indexed_at)
      Check.new(name: "embedding_pipeline", status: :info,
                details: { indexed_hosts: indexed, total_hosts: total, ratio: ratio, last_indexed_at: last&.iso8601 })
    rescue ActiveRecord::ActiveRecordError, PG::Error => e
      Check.new(name: "embedding_pipeline", status: :unknown, details: e.message[0, 80])
    end
    ```
  - **Test plan** : Spec doctor étendue : `embedding_pipeline` retourne les 4 clefs ; quand table absente, `status=:unknown`.

---

## 5. Documentation

- [x] **5.1 `docs/operating/embedding-pipeline.md`**
  - **Notes** : Documente le flux : (a) host créé → IndexHostJob enqueueé → ligne embeddings, (b) hook update partiel (champs pertinents only), (c) job retry sur embedder down, (d) procédure de réindexation, (e) limitations (mono-thread, pas de re-index sur service change). Inclut un troubleshooting "agent_chat retourne rows vides" qui pointe vers `reconaut:doctor` et `reconaut:reindex`.
  - **Test plan** : `grep -c "IndexHostJob\|reconaut:reindex\|reindex" docs/operating/embedding-pipeline.md` retourne ≥ 5.

- [x] **5.2 Ajout dans `mkdocs.yml` nav**
  - **Notes** : Sous "Opérationnel" ajouter "Pipeline d'embedding". `mkdocs build --strict` doit passer.

---

## 6. Acceptance pour le change dans son ensemble

- [x] **6.1 Test système : indexation → recherche**
  - Spec `spec/integration/embedding_pipeline_spec.rb` :
    - (a) Crée 3 hosts en base.
    - (b) Force l'exécution synchrone des `IndexHostJob` (`perform_now` ou drain GoodJob).
    - (c) Invoque `agent_chat` via HTTP → 3 `rows` retournés.
    - (d) Sans purge, changement de fqdn d'un host → re-index → la query retourne le nouveau fingerprint.

- [x] **6.2 Aucune régression**
  - Suite RSpec actuelle (535 examples) reste verte. Les 10 linters CI restent verts.

- [x] **6.3 Tick acceptance line `init §238`**
  - L'acceptance line `Chaque exigence des spec deltas (...ai-optimization...)` est encore ouverte mais ce change couvre `agent-interface`. Documenter dans le statut que `agent-interface` est désormais 100% testée en CI.

- [x] **6.4 Smoke test live**
  - Après merge, sur l'instance dev de l'opérateur : `RECONAUT_MCP_TLS_REQUIRED=false bundle exec rails server` + un `POST /mcp/tools/agent_chat` retourne des `rows` réels (pas le `retriever-not-wired` warning).
