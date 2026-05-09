# Tâches : add-persistent-auth-storage

Checklist de la migration in-memory → ActiveRecord pour les `users` et `api_keys`. Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Schéma Postgres

- [x] **1.1 Migration `create_auth_tables`**
  - **Notes** : Nouvelle migration `apps/api/db/migrate/<ts>_create_auth_tables.rb` qui crée :
    ```ruby
    enable_extension "citext"
    create_table :users, id: :uuid do |t|
      t.column :email, :citext, null: false
      t.string :password_hash, null: false
      t.timestamp :created_at, null: false, default: -> { "now()" }
      t.timestamp :disabled_at
    end
    add_index :users, :email, unique: true
    create_table :api_keys, id: :uuid do |t|
      t.references :user, type: :uuid, foreign_key: { on_delete: :cascade }, null: false, index: true
      t.string :prefix, limit: 8, null: false
      t.string :token_hash, limit: 64, null: false
      t.column :scopes, "text[]", null: false, default: "{}"
      t.timestamp :created_at, null: false, default: -> { "now()" }
      t.timestamp :revoked_at
    end
    add_index :api_keys, :token_hash, unique: true
    ```
    Aucune colonne `tenant_id`.
  - **Test plan** : `bin/rails db:migrate` puis `\d users` et `\d api_keys` (via `psql`) montrent les colonnes attendues. `bin/rails db:rollback` puis re-`migrate` doivent être idempotents.

- [x] **1.2 Linter check_stack continue à passer**
  - **Notes** : la migration ne contient pas `tenant_id` ; `scripts/check_stack.sh` continue à exiger zéro mention.
  - **Test plan** : `bash scripts/check_stack.sh` retourne 0.

---

## 2. Modèles ActiveRecord

- [x] **2.1 Modèle `Reconaut::Auth::ARUser`**
  - **Notes** : Nouveau fichier `apps/api/app/models/reconaut/auth/ar_user.rb`. Modèle minimaliste :
    ```ruby
    class Reconaut::Auth::ARUser < ApplicationRecord
      self.table_name = "users"
      has_many :ar_api_keys, class_name: "Reconaut::Auth::ARApiKey", foreign_key: :user_id, dependent: :destroy
    end
    ```
    Le namespace `Reconaut::Auth::AR*` évite la collision avec le `Struct User` existant.
  - **Test plan** : `Reconaut::Auth::ARUser.create!(email: "x@y", password_hash: "h")` insère une ligne. Conflit unique sur l'email → `ActiveRecord::RecordNotUnique`.

- [x] **2.2 Modèle `Reconaut::Auth::ARApiKey`**
  - **Notes** : Pendant `apps/api/app/models/reconaut/auth/ar_api_key.rb` :
    ```ruby
    class Reconaut::Auth::ARApiKey < ApplicationRecord
      self.table_name = "api_keys"
      belongs_to :ar_user, class_name: "Reconaut::Auth::ARUser", foreign_key: :user_id
    end
    ```
  - **Test plan** : Création d'une ARApiKey rattachée à une ARUser ; `ARApiKey.find_by(token_hash: ...)` retourne la ligne.

---

## 3. Adapters Storage

- [x] **3.1 `Storage::ActiveRecordUsers`**
  - **Notes** : Nouvelle classe dans `apps/api/app/lib/reconaut/auth/storage.rb` (ou fichier séparé `storage/active_record_users.rb`). Implémente la même interface que `InMemoryUsers` mais persiste via `ARUser`. Mapping `ARUser` ↔ `User` Struct via une méthode privée `to_struct(ar)` qui formatte `created_at`/`disabled_at` en ISO-8601 UTC.
    ```ruby
    def create(email:, password_hash:, role: nil)
      _ = role
      email = email.to_s.downcase.strip
      raise ArgumentError, "invalid_email" if email.empty? || !email.include?("@")
      ar = ARUser.create!(email: email, password_hash: password_hash)
      to_struct(ar)
    rescue ActiveRecord::RecordNotUnique
      raise ArgumentError, "email_taken"
    end
    ```
  - **Test plan** : Le module `SharedExamples::AuthStorage` (cf. §4) s'applique 1:1 ; tous les tests passent.

- [x] **3.2 `Storage::ActiveRecordApiKeys`**
  - **Notes** : Pendant pour les clés API. La méthode `create_for` génère le `raw_token` (SecureRandom), calcule le `token_hash` (SHA-256), insère via `ARApiKey.create!`, retourne `[struct, raw_token]`. `revoke_all!` fait `ARApiKey.where(revoked_at: nil).update_all(revoked_at: Time.now.utc)`.
  - **Test plan** : Le SharedExamples passe ; un test dédié vérifie que `find_by_token(raw)` n'invoque PAS `password_hasher.verify` (c'est juste un lookup par hash).

- [x] **3.3 Mapping AR ↔ Struct fidèle**
  - **Notes** : Les attributs `created_at` / `disabled_at` / `revoked_at` doivent être sérialisés en ISO-8601 UTC string (cohérent avec `InMemoryUsers` qui utilise `Time.now.utc.iso8601`). Le test compare octet-pour-octet.
  - **Test plan** : `expect(ar_users.create(...).created_at).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)`.

---

## 4. Tests partagés

- [x] **4.1 Module `SharedExamples::AuthStorage`**
  - **Notes** : Extraire les assertions communes de `spec/lib/reconaut/auth/storage_spec.rb` actuel dans un module `apps/api/spec/support/shared_examples/auth_storage.rb`. Le module définit `shared_examples "an auth storage"` avec un `let(:user_store)` et `let(:api_key_store)` que chaque suite spécialise.
  - **Test plan** : `rspec spec/lib/reconaut/auth/storage_spec.rb` continue à passer (in-memory backend).

- [x] **4.2 Spec dédiée à l'adapter ActiveRecord**
  - **Notes** : Nouveau fichier `apps/api/spec/lib/reconaut/auth/storage_active_record_spec.rb` qui inclut le SharedExamples avec :
    ```ruby
    let(:user_store) { Reconaut::Auth::Storage::ActiveRecordUsers.new }
    let(:api_key_store) { Reconaut::Auth::Storage::ActiveRecordApiKeys.new }
    before { Reconaut::Auth::ARApiKey.delete_all; Reconaut::Auth::ARUser.delete_all }
    ```
  - **Test plan** : `rspec spec/lib/reconaut/auth/storage_active_record_spec.rb` passe avec exactement les mêmes 22+ examples que la version in-memory.

---

## 5. Wiring Registry

- [x] **5.1 Détection runtime du backend dans `Registry#initialize`**
  - **Notes** : Modifier `apps/api/app/lib/reconaut/registry.rb` pour choisir le backend :
    ```ruby
    @user_store, @api_key_store = if active_record_ready?
      [Storage::ActiveRecordUsers.new, Storage::ActiveRecordApiKeys.new]
    else
      [Storage::InMemoryUsers.new, Storage::InMemoryApiKeys.new]
    end
    ```
    avec `active_record_ready?` qui retourne `true` SSI `ActiveRecord::Base.connected?` ET la table `users` existe (`ActiveRecord::Base.connection.table_exists?(:users)`).
  - **Test plan** : Test unitaire qui instancie un Registry sans connexion AR (`ActiveRecord::Base.remove_connection`) → backend in-memory. Avec connexion + table → backend AR.

- [x] **5.2 La rake task `reconaut:set_password` persiste**
  - **Notes** : Aucune modification à la rake task elle-même : elle utilise `Bootstrap.call` qui passe par `Registry.default`, qui choisit AR. Le commentaire dans la rake mentionne maintenant la persistance Postgres.
  - **Test plan** : Test système (acceptance) — cf. §7.1.

---

## 6. Documentation

- [x] **6.1 Mise à jour de `docs/architecture/auth-bootstrap.md`**
  - **Notes** : La doc mentionne actuellement le store in-memory. Réécrire la section "Storage" pour décrire le couple AR/in-memory et le switch automatique.
  - **Test plan** : `grep -i "ActiveRecord\|persistant\|persist" docs/architecture/auth-bootstrap.md` retourne ≥ 2 matches.

- [x] **6.2 Note dans `docs/operating/responsibility-model.md`**
  - **Notes** : Ajouter une note brève dans la section "Ce que Reconaut stocke" qui explicite : `users` (email + hash) + `api_keys` (prefix + token_hash + scopes), pas de PII.
  - **Test plan** : `grep -i "users\|api_keys" docs/operating/responsibility-model.md` retourne ≥ 1 match.

---

## 7. Acceptance pour le change dans son ensemble

- [x] **7.1 Test système : bootstrap depuis un process, login depuis un autre**
  - **Notes** : Spec d'intégration `spec/integration/auth_persistence_spec.rb` qui :
    1. `Reconaut::Auth::Bootstrap.call(email: "operator@local", password: "secret", rotate: false)` (simule la rake task).
    2. **Reset** le `Registry.default` (`Reconaut::Registry.reset!`) — simule un nouveau process.
    3. Tape `POST /auth/sessions` avec `password: "secret"` via `Rack::Test`.
    4. Asserte que la réponse est 201 + un `api_key.token`.
  - **Test plan** : `rspec spec/integration/auth_persistence_spec.rb` passe.

- [x] **7.2 Aucune régression**
  - Toute la suite RSpec actuelle (414 examples avant ce change) reste verte.
  - Tous les linters CI (`stack`, `rest_allowlist`, `tui_mcp_only`, `scanner_specialization`, `spdx_headers`, `ssh_probe_no_auth`) restent verts.

- [x] **7.3 Migration idempotente**
  - `bin/rails db:migrate` puis `bin/rails db:rollback STEP=1` puis `bin/rails db:migrate` doit retomber sur le même schéma exactement (vérifié via `db/schema.rb`).

- [x] **7.4 Fingerprint dans `reconaut:doctor`**
  - **Notes** : La task `reconaut:doctor` mentionne maintenant la présence de la table `users` et le nombre de clés API actives (count `revoked_at IS NULL`).
  - **Test plan** : `bundle exec rails reconaut:doctor` imprime un champ `auth_storage: { backend: "active_record", users: 1, api_keys_active: N }`.
