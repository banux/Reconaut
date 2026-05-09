# frozen_string_literal: true

require "rails_helper"

# Spec d'intégration cross-process : simule la séquence
#   1. `bundle exec rails reconaut:set_password` (un process)
#   2. `reconautctl login` (autre process) → POST /auth/sessions
# en :
#   - appelant Reconaut::Auth::Bootstrap.call (équivalent rake task)
#   - puis Reconaut::Registry.reset! (simule un nouveau process : nouveau
#     singleton Registry, donc nouvelle Authenticator, mais la base
#     Postgres est partagée)
#   - puis POST /auth/sessions via Rack::Test
#
# Cf. openspec/changes/add-persistent-auth-storage/specs/platform/spec.md
#   -> Scenario: Cycle bootstrap → login depuis un autre process

RSpec.describe "Auth persistence cross-process", type: :request do
  before do
    # Reset systématique : la base est partagée mais les state mémoires
    # (Registry singleton + password_hasher Plain par défaut) sont
    # neutralisés.
    Reconaut::Registry.reset!
  end

  after { Reconaut::Registry.reset! }

  # On utilise Argon2id ici (pas Plain) — le bootstrap stocke un hash
  # qui doit être vérifiable par le serveur (autre process).
  it "bootstrap puis login depuis un Registry réinitialisé fonctionne (DB partagée)" do
    # Étape 1 : équivalent rake task — bootstrap dans un Registry.
    Reconaut::Registry.default.password_hasher = Reconaut::Auth::PasswordHasher::Argon2id.new
    Reconaut::Auth::Bootstrap.call(
      email:    "operator@local",
      password: "solkanar",
      rotate:   false
    )

    expect(Reconaut::Auth::ArUser.count).to eq(1)
    expect(Reconaut::Auth::ArApiKey.count).to eq(1) # une clé créée par Bootstrap

    # Étape 2 : "nouveau process" — wipe le singleton, le hash en
    # mémoire est perdu, mais la base reste.
    Reconaut::Registry.reset!
    Reconaut::Registry.default.password_hasher = Reconaut::Auth::PasswordHasher::Argon2id.new

    # Sanity : le user a bien été persisté en DB et est lu par le
    # nouveau Registry.
    expect(Reconaut::Registry.default.user_store.list.size).to eq(1)
    expect(Reconaut::Registry.default.user_store.find_by_email("operator@local")).not_to be_nil

    # Étape 3 : POST /auth/sessions avec le password.
    post "/auth/sessions",
         params:  { password: "solkanar" }.to_json,
         headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:api_key][:token]).to be_a(String)
    expect(body[:api_key][:scopes]).to be_an(Array)
    expect(body[:user][:email]).to eq("operator@local")
  end

  it "rotation du password révoque toutes les clés existantes en DB" do
    Reconaut::Registry.default.password_hasher = Reconaut::Auth::PasswordHasher::Argon2id.new
    Reconaut::Auth::Bootstrap.call(
      email:    "operator@local",
      password: "old-pwd",
      rotate:   false
    )
    initial_key_id = Reconaut::Auth::ArApiKey.first.id

    # Rotation
    Reconaut::Registry.reset!
    Reconaut::Registry.default.password_hasher = Reconaut::Auth::PasswordHasher::Argon2id.new
    Reconaut::Auth::Bootstrap.call(
      email:    "operator@local",
      password: "new-pwd",
      rotate:   true
    )

    # L'ancienne clé est révoquée.
    expect(Reconaut::Auth::ArApiKey.find(initial_key_id).revoked_at).not_to be_nil
    # Une nouvelle clé existe (la rotation en émet une).
    expect(Reconaut::Auth::ArApiKey.where(revoked_at: nil).count).to eq(1)

    # Login avec l'ancien password échoue, le nouveau réussit.
    post "/auth/sessions", params: { password: "old-pwd" }.to_json,
                           headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)

    post "/auth/sessions", params: { password: "new-pwd" }.to_json,
                           headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:created)
  end

  it "second Bootstrap.call sans rotate lève AlreadyInitializedError (mode mono-user)" do
    Reconaut::Registry.default.password_hasher = Reconaut::Auth::PasswordHasher::Argon2id.new
    Reconaut::Auth::Bootstrap.call(email: "operator@local", password: "x", rotate: false)

    Reconaut::Registry.reset!
    Reconaut::Registry.default.password_hasher = Reconaut::Auth::PasswordHasher::Argon2id.new
    expect do
      Reconaut::Auth::Bootstrap.call(email: "alice@local", password: "y", rotate: false)
    end.to raise_error(Reconaut::Auth::Bootstrap::AlreadyInitializedError)

    expect(Reconaut::Auth::ArUser.count).to eq(1)
    expect(Reconaut::Auth::ArUser.first.email).to eq("operator@local")
  end

  it "token_hash en colonne, jamais le token brut" do
    Reconaut::Registry.default.password_hasher = Reconaut::Auth::PasswordHasher::Argon2id.new
    Reconaut::Auth::Bootstrap.call(email: "operator@local", password: "x", rotate: false)

    raw_tokens_in_db = Reconaut::Auth::ArApiKey.pluck(:token_hash)
    expect(raw_tokens_in_db.size).to be >= 1
    raw_tokens_in_db.each do |th|
      expect(th).to match(/\A[0-9a-f]{64}\z/) # SHA-256 hex
    end
  end
end
