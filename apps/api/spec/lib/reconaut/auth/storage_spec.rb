# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../app/lib/reconaut/auth/storage"

RSpec.describe Reconaut::Auth::Storage do
  describe Reconaut::Auth::Storage::InMemoryUsers do
    subject(:store) { described_class.new }

    it "create + find_by_email + find" do
      user = store.create(email: "Alice@example.com", password_hash: "h1")
      expect(user.email).to eq("alice@example.com") # downcase + trim
      expect(store.find_by_email("alice@example.com").id).to eq(user.id)
      expect(store.find(user.id).id).to eq(user.id)
    end

    it "User n'a plus de champ role (mono-user)" do
      user = store.create(email: "a@b.c", password_hash: "h")
      expect(user).not_to respond_to(:role)
      expect(user.to_h).not_to have_key(:role)
    end

    it "create accepte le kwarg role: pour rétrocompatibilité mais l'ignore" do
      user = store.create(email: "a@b.c", password_hash: "h", role: :owner)
      expect(user).not_to respond_to(:role)
    end

    it "rejette un email invalide" do
      expect { store.create(email: "not-an-email", password_hash: "h") }
        .to raise_error(ArgumentError, /invalid_email/)
    end

    it "rejette un email deja pris" do
      store.create(email: "a@b.c", password_hash: "h")
      expect { store.create(email: "a@b.c", password_hash: "h") }
        .to raise_error(ArgumentError, /email_taken/)
    end

    it "User#to_h n'expose JAMAIS le password_hash" do
      user = store.create(email: "a@b.c", password_hash: "supersecret")
      h = user.to_h
      expect(h).not_to have_key(:password_hash)
      expect(h.values.map(&:to_s).join("|")).not_to include("supersecret")
    end

    it "disable! marque l'utilisateur comme disabled" do
      user = store.create(email: "a@b.c", password_hash: "h")
      disabled = store.disable!(user.id)
      expect(disabled.disabled?).to be true
      expect(store.find(user.id).disabled?).to be true
    end
  end

  describe Reconaut::Auth::Storage::InMemoryApiKeys do
    subject(:store) { described_class.new }

    it "create_for renvoie [record, raw] avec hash sha256 du raw" do
      record, raw = store.create_for(user_id: "u-1")
      expect(raw).to match(/\A[A-Za-z0-9_-]{30,}\z/)
      expect(record.token_hash).to eq(Digest::SHA256.hexdigest(raw))
      expect(record.prefix).to eq(raw[0, 8])
      expect(record.user_id).to eq("u-1")
    end

    it "find_by_token retrouve la cle a partir du raw" do
      record, raw = store.create_for(user_id: "u-1")
      found = store.find_by_token(raw)
      expect(found.id).to eq(record.id)
    end

    it "find_by_token sur un token absent renvoie nil" do
      expect(store.find_by_token("nope")).to be_nil
      expect(store.find_by_token("")).to be_nil
    end

    it "list_for filtre par user_id" do
      _, _ = store.create_for(user_id: "u-1")
      _, _ = store.create_for(user_id: "u-2")
      _, _ = store.create_for(user_id: "u-1")
      expect(store.list_for("u-1").size).to eq(2)
      expect(store.list_for("u-2").size).to eq(1)
    end

    it "revoke! marque la cle comme revoquee" do
      record, raw = store.create_for(user_id: "u-1")
      store.revoke!(record.id)
      found = store.find_by_token(raw)
      expect(found.revoked?).to be true
    end

    it "ApiKey#to_h n'expose JAMAIS le token_hash" do
      record, _raw = store.create_for(user_id: "u-1")
      expect(record.to_h).not_to have_key(:token_hash)
    end
  end
end
