# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Shared examples — assertions communes aux deux backends (in-memory et
# ActiveRecord) du store d'auth.
#
# Cf. openspec/changes/add-persistent-auth-storage/specs/platform/spec.md
#   -> Requirement: Backend de stockage auth interchangeable
#
# Les suites parentes définissent :
#   - `let(:user_store)` : instance d'un Users-store
#   - `let(:api_key_store)` : instance d'un ApiKeys-store

require "digest"

RSpec.shared_examples "an auth users store" do
  it "create + find_by_email + find" do
    user = user_store.create(email: "Alice@example.com", password_hash: "h1")
    expect(user.email).to eq("alice@example.com") # downcase + trim
    expect(user_store.find_by_email("alice@example.com").id).to eq(user.id)
    expect(user_store.find(user.id).id).to eq(user.id)
  end

  it "User n'a plus de champ role (mono-user)" do
    user = user_store.create(email: "a@b.c", password_hash: "h")
    expect(user).not_to respond_to(:role)
    expect(user.to_h).not_to have_key(:role)
  end

  it "create accepte le kwarg role: pour rétrocompatibilité mais l'ignore" do
    user = user_store.create(email: "a@b.c", password_hash: "h", role: :owner)
    expect(user).not_to respond_to(:role)
  end

  it "rejette un email invalide" do
    expect { user_store.create(email: "not-an-email", password_hash: "h") }
      .to raise_error(ArgumentError, /invalid_email/)
  end

  it "rejette un email déjà pris" do
    user_store.create(email: "a@b.c", password_hash: "h")
    expect { user_store.create(email: "a@b.c", password_hash: "h") }
      .to raise_error(ArgumentError, /email_taken/)
  end

  it "User#to_h n'expose JAMAIS le password_hash" do
    user = user_store.create(email: "a@b.c", password_hash: "supersecret")
    h = user.to_h
    expect(h).not_to have_key(:password_hash)
    expect(h.values.map(&:to_s).join("|")).not_to include("supersecret")
  end

  it "disable! marque l'utilisateur comme disabled" do
    user = user_store.create(email: "a@b.c", password_hash: "h")
    disabled = user_store.disable!(user.id)
    expect(disabled.disabled?).to be true
    expect(user_store.find(user.id).disabled?).to be true
  end

  it "set_password_hash! met à jour le hash" do
    user = user_store.create(email: "a@b.c", password_hash: "old")
    updated = user_store.set_password_hash!(user.id, "new")
    expect(updated.password_hash).to eq("new")
    expect(user_store.find(user.id).password_hash).to eq("new")
  end

  it "set_password_hash! sur un id inconnu renvoie nil" do
    expect(user_store.set_password_hash!("nope", "h")).to be_nil
  end

  it "list renvoie un Array" do
    user_store.create(email: "a@b.c", password_hash: "h")
    expect(user_store.list).to be_an(Array)
    expect(user_store.list.size).to eq(1)
  end

  it "created_at est ISO-8601 UTC" do
    user = user_store.create(email: "a@b.c", password_hash: "h")
    expect(user.created_at).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
  end
end

RSpec.shared_examples "an auth api_keys store" do
  it "create_for renvoie [record, raw] avec hash sha256 du raw" do
    record, raw = api_key_store.create_for
    expect(raw).to match(/\A[A-Za-z0-9_-]{30,}\z/)
    expect(record.token_hash).to eq(Digest::SHA256.hexdigest(raw))
    expect(record.prefix).to eq(raw[0, 8])
  end

  it "create_for accepte un set de scopes explicite (clé scopée)" do
    record, _ = api_key_store.create_for(scopes: [:"read:hosts", :"read:scans"])
    expect(record.scopes).to eq([:"read:hosts", :"read:scans"])
  end

  it "create_for sans scopes attribue le set DEFAULT_SCOPES" do
    record, _ = api_key_store.create_for
    expected = api_key_store.class::DEFAULT_SCOPES
    expect(record.scopes).to eq(expected)
    expect(record.to_h[:scopes]).to be_an(Array)
  end

  it "find_by_token retrouve la clé à partir du raw" do
    record, raw = api_key_store.create_for
    found = api_key_store.find_by_token(raw)
    expect(found.id).to eq(record.id)
  end

  it "find_by_token sur un token absent renvoie nil" do
    expect(api_key_store.find_by_token("nope")).to be_nil
    expect(api_key_store.find_by_token("")).to be_nil
  end

  it "list renvoie toutes les clés (mono-user, plus de filtrage user_id)" do
    3.times { api_key_store.create_for }
    expect(api_key_store.list.size).to eq(3)
  end

  it "revoke! marque la clé comme révoquée" do
    record, raw = api_key_store.create_for
    api_key_store.revoke!(record.id)
    found = api_key_store.find_by_token(raw)
    expect(found.revoked?).to be true
  end

  it "revoke_all! révoque toutes les clés non révoquées" do
    r1, _ = api_key_store.create_for
    r2, _ = api_key_store.create_for
    api_key_store.revoke_all!
    remaining = api_key_store.list
    expect(remaining.all?(&:revoked?)).to be true
    expect(remaining.map(&:id)).to include(r1.id, r2.id)
  end

  it "ApiKey#to_h n'expose JAMAIS le token_hash" do
    record, _raw = api_key_store.create_for
    expect(record.to_h).not_to have_key(:token_hash)
  end

  it "created_at est ISO-8601 UTC" do
    record, _raw = api_key_store.create_for
    expect(record.created_at).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
  end
end
