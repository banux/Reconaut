# Tâches : add-embedder-pluggable

Checklist de la mise en production de l'embedder pluggable : table pgvector + résilience + boot validation + doctor. Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Schéma Postgres : table embeddings + index HNSW

- [x] **1.1 Migration `create_embeddings_table`**
  - **Notes** : Nouvelle migration `apps/api/db/migrate/<ts>_create_embeddings_table.rb` :
    ```ruby
    # extension `vector` déjà activée par enable_graph_extensions
    create_table :embeddings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :host, type: :uuid, foreign_key: { on_delete: :cascade }, null: false, index: true
      t.text   :content, null: false
      t.column :vector, "vector(384)", null: false
      t.string :provider, null: false, limit: 32
      t.string :model,    null: false, limit: 128
      t.integer :dim,     null: false
      t.timestamp :indexed_at, null: false, default: -> { "now()" }
    end
    add_check_constraint :embeddings, "provider IN ('local','ollama','mistral','openai-compatible')"
    add_check_constraint :embeddings, "dim > 0 AND dim <= 4096"
    execute "CREATE INDEX idx_embeddings_vector_hnsw ON embeddings USING hnsw (vector vector_cosine_ops)"
    ```
  - **Test plan** : `bin/rails db:migrate` puis `\d embeddings` montre les colonnes et l'index HNSW. `bin/rails db:rollback STEP=1` puis re-`migrate` est idempotent. Spec `spec/models/embedding_spec.rb` insère une ligne avec `vector = '[0,0,...,0]'::vector` et confirme la persistance.

- [x] **1.2 Modèle `Embedding`**
  - **Notes** : `apps/api/app/models/embedding.rb` minimaliste :
    ```ruby
    class Embedding < ApplicationRecord
      belongs_to :host
      validates :content, :provider, :model, :dim, presence: true
    end
    ```
  - **Test plan** : Spec d'unitaire vérifie validations + cascade DELETE quand l'hôte parent est supprimé.

- [x] **1.3 Linter check_stack reste vert**
  - **Notes** : Aucune colonne `tenant_id` dans la migration. Aucun import de SDK analytics ou billing.
  - **Test plan** : `bash scripts/check_stack.sh && bash scripts/check_no_billing.sh` retournent 0.

---

## 2. Wrapper de résilience

- [x] **2.1 Classe `Reconaut::Embedder::Resilient`**
  - **Notes** : Nouveau fichier `apps/api/app/lib/reconaut/embedder/resilient.rb`. Décorateur :
    ```ruby
    class Resilient
      def initialize(inner, timeout_s:, breaker_failures:, breaker_window_s:, breaker_open_s:)
        @inner = inner
        @timeout_s = timeout_s
        @breaker = Breaker.new(failures: breaker_failures, window_s: breaker_window_s, open_s: breaker_open_s)
        @stats = { failures_total: 0, circuit_state: :closed, last_error: nil }
      end

      def embed(texts:)
        raise CircuitOpenError if @breaker.open?
        Timeout.timeout(@timeout_s) { @inner.embed(texts: texts) }
      rescue Timeout::Error
        record_failure!("timeout")
        raise TimeoutError
      rescue UnavailableError => e
        record_failure!(e.message[0, 80])
        raise
      end

      def dim = @inner.dim
      def provider = @inner.provider
      def stats = @stats.merge(circuit_state: @breaker.state)
    end
    ```
  - **Test plan** : Spec dédiée `apps/api/spec/lib/reconaut/embedder/resilient_spec.rb` couvre : (a) succès passe-plat, (b) `UnavailableError` propagée + compteur incrémenté, (c) timeout déclenché à `timeout_s` ± 100 ms, (d) après N échecs circuit `:open`, (e) après `open_s` circuit `:half_open` autorise un essai, (f) succès en `half_open` rebascule à `:closed`.

- [x] **2.2 Circuit breaker `Reconaut::Embedder::Breaker`**
  - **Notes** : Implémentation maison ~50 lignes. État interne : `@failures` (Array<Time>), `@opened_at` (Time | nil). Méthodes : `record_failure!`, `record_success!`, `open?`, `state`. Pas de mutex global — Ruby GIL protège les opérations atomiques sur Array, et le wrapper est thread-local par requête Rails.
  - **Test plan** : Inclus dans le spec `Resilient`. Test additionnel : `Breaker#state` enum strict `[:closed, :open, :half_open]`.

- [x] **2.3 Erreurs typées**
  - **Notes** : Ajouter dans `reconaut/embedder.rb` :
    ```ruby
    class TimeoutError < StandardError; end
    class CircuitOpenError < StandardError; end
    ```
    `UnavailableError` existe déjà.
  - **Test plan** : Hiérarchie `TimeoutError < StandardError`, `CircuitOpenError < StandardError`. Pas d'héritage de `UnavailableError` (elles ont des sémantiques différentes : timeout = problème de latence, circuit = protection préventive, unavailable = backend cassé).

- [x] **2.4 `Embedder.build` enveloppe automatiquement les providers réseau**
  - **Notes** : Modifier `Embedder.build(env:)` pour wrapper `Ollama`, `Mistral`, `OpenAICompatible` dans `Resilient` avec les seuils lus depuis env (defaults : 2.5/5/30/60). `Local` retourné tel quel.
  - **Test plan** : Spec `build_spec.rb` étendu : `provider=local` → instance `Local` directe ; `provider=ollama` (avec env complet) → instance `Resilient` qui enveloppe `Ollama`. Test : `Embedder.build(env: stub).is_a?(Resilient)` selon le provider.

---

## 3. Validation au boot

- [x] **3.1 Initializer `embedder_validation.rb`**
  - **Notes** : `apps/api/config/initializers/embedder_validation.rb` qui appelle `Reconaut::Embedder.build(env: ENV)` au boot et logue le résultat. En cas de `MisconfiguredError`, `abort` avec code ≠ 0 et message clair. Le check tourne UNIQUEMENT en environnements `production` et `development` — en `test`, le boot ne doit pas échouer si la config est minimale (les tests injectent leurs propres embedders).
  - **Test plan** : Test système qui boote l'app avec `RAILS_ENV=production RECONAUT_EMBEDDER_PROVIDER=ollama` (sans URL) → `Process` exit ≠ 0, stderr contient `embedder-misconfigured`. Test inverse : boot avec config valide → exit 0 et log `[embedder] provider=...`.

---

## 4. Mapping HTTP 503 dans le controller agent

- [x] **4.1 `Agent::ChatController` rattrape les erreurs embedder**
  - **Notes** : Modifier `apps/api/app/controllers/agent/chat_controller.rb` (ou son use case) pour rattraper `Reconaut::Embedder::UnavailableError`, `TimeoutError`, `CircuitOpenError` et renvoyer **HTTP 503** avec body `{"error":"embedding_provider_unavailable","provider":<name>,"reason":<short>}`. Le `provider` est lu depuis l'embedder injecté dans le retriever.
  - **Test plan** : Spec request injecte un fake embedder qui lève chacune des 3 erreurs ; assure (a) status 503, (b) body contient `embedding_provider_unavailable`, (c) `provider` correctement reporté, (d) audit log écrit avec `template_id=agent:chat, status=success`.

---

## 5. Visibilité opérationnelle : reconaut:doctor

- [x] **5.1 Check `embedder_health` dans `Reconaut::Doctor`**
  - **Notes** : Ajouter `check_embedder_health(probes, ctx)` dans `apps/api/app/lib/reconaut/doctor.rb`. Lit l'embedder via `Reconaut::Registry.default.embedder` (à exposer si pas déjà fait) ou directement via `Embedder.build(env: ENV)` pour ne pas dépendre du registry. Imprime `{provider, dim, circuit_state, failures_total}`. Status `:info` (pas `:fail`) — le doctor ne tente pas un appel réel pour ne pas perturber la prod.
  - **Test plan** : Spec `doctor_spec.rb` étendu : check présent, statut `:info`, details contient les 4 clefs.

---

## 6. Documentation

- [x] **6.1 Mise à jour de `docs/operating/responsibility-model.md`**
  - **Notes** : Ajouter une note dans la section "Ce que Reconaut stocke" : `embeddings` (vecteur 384, content text, provider/model). Pas de PII.
  - **Test plan** : `grep -i "embeddings" docs/operating/responsibility-model.md` retourne ≥ 1 match.

- [x] **6.2 Nouveau fichier `docs/operating/embedder-providers.md`**
  - **Notes** : Documentation opérateur des 4 providers : variables d'environnement, modèles recommandés, dim attendue, considérations de coût/latence/souveraineté. Inclut un exemple complet pour chaque provider.
  - **Test plan** : `grep -i "RECONAUT_EMBEDDER_PROVIDER" docs/operating/embedder-providers.md` retourne ≥ 4 occurrences (une par provider).

---

## 7. Acceptance pour le change dans son ensemble

- [x] **7.1 Aucune régression**
  - Toute la suite RSpec actuelle (457 examples avant ce change) reste verte. Les 16 specs `embedder/contract_spec.rb` + 8 `build_spec.rb` continuent de passer.
  - Tous les linters CI (`stack`, `rest_allowlist`, `tui_mcp_only`, `scanner_specialization`, `spdx_headers`, `ssh_probe_no_auth`, `no_billing`) restent verts.

- [x] **7.2 Migration idempotente**
  - `bin/rails db:migrate` puis `bin/rails db:rollback STEP=1` puis `bin/rails db:migrate` retombe sur le même schéma. Index HNSW présent.

- [x] **7.3 Cycle complet d'intégration**
  - Spec d'intégration `spec/integration/embedder_pluggable_spec.rb` : (a) boot avec `RECONAUT_EMBEDDER_PROVIDER=local` réussit ; (b) un fake embedder qui lève `UnavailableError` → `/agent/chat` répond 503 ; (c) après 5 échecs le circuit est `:open` ; (d) `reconaut:doctor` reporte le `circuit_state`.

- [x] **7.4 Provider local toujours zéro réseau**
  - Spec qui stubbe `Net::HTTP.start → raise "boom"` puis appelle `Embedder.build(env: { "RECONAUT_EMBEDDER_PROVIDER" => "local" }).embed(texts: ["x"])` — passe sans erreur (preuve que `Resilient` n'enveloppe PAS `Local` et qu'aucun chemin ne sort sur le réseau).
