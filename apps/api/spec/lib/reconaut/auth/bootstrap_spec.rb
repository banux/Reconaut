# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../app/lib/reconaut/auth/bootstrap"
require_relative "../../../../app/lib/reconaut/registry"

RSpec.describe Reconaut::Auth::Bootstrap do
  let(:registry) { Reconaut::Registry.new }

  describe ".call" do
    it "cree le user et issue une cle API la premiere fois" do
      result = described_class.call(
        email: "owner@reconaut.local",
        password: "hunter2",
        registry: registry
      )

      expect(result[:user].email).to eq("owner@reconaut.local")
      expect(result[:user]).not_to respond_to(:role) # mono-user
      expect(result[:api_key][:token]).to be_a(String)
      expect(registry.user_store.list.size).to eq(1)
      expect(registry.api_key_store.list_for(result[:user].id).size).to eq(1)
    end

    it "leve AlreadyInitializedError si un user existe deja" do
      registry.user_store.create(
        email: "existing@x.y",
        password_hash: registry.password_hasher.hash("p")
      )

      expect {
        described_class.call(email: "second@x.y", password: "p", registry: registry)
      }.to raise_error(described_class::AlreadyInitializedError)
    end

    it "email vide est coerce vers DEFAULT_OPERATOR_EMAIL (mono-user)" do
      result = described_class.call(email: "  ", password: "p", registry: registry)
      expect(result[:user].email).to eq(described_class::DEFAULT_OPERATOR_EMAIL)
    end

    it "email omis utilise DEFAULT_OPERATOR_EMAIL" do
      result = described_class.call(password: "p", registry: registry)
      expect(result[:user].email).to eq(described_class::DEFAULT_OPERATOR_EMAIL)
    end

    it "leve MissingCredentialsError si password vide" do
      expect {
        described_class.call(email: "a@b.c", password: "", registry: registry)
      }.to raise_error(described_class::MissingCredentialsError)
    end

    it "le hash stocke n'est PAS le password en clair (avec Argon2id)" do
      registry.password_hasher = Reconaut::Auth::PasswordHasher::Argon2id.new(t_cost: 1, m_cost: 8)
      result = described_class.call(
        email: "a@b.c", password: "supersecret", registry: registry
      )
      stored = registry.user_store.find(result[:user].id)
      expect(stored.password_hash).not_to include("supersecret")
      expect(stored.password_hash).to start_with("$argon2id$")
    end

    it "round trip : la cle issue authentifie immediatement le user" do
      result = described_class.call(
        email: "a@b.c", password: "p", registry: registry
      )
      identity = registry.authenticator.from_authorization("Bearer #{result[:api_key][:token]}")
      expect(identity).not_to be_nil
      expect(identity.user.id).to eq(result[:user].id)
      # Mode mono-user : tout user authentifié a role :operator.
      expect(identity.role).to eq(:operator)
    end
  end
end
