# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../app/lib/reconaut/auth/authenticator"

RSpec.describe Reconaut::Auth::Authenticator do
  let(:users) { Reconaut::Auth::Storage::InMemoryUsers.new }
  let(:keys)  { Reconaut::Auth::Storage::InMemoryApiKeys.new }
  let(:hasher) { Reconaut::Auth::PasswordHasher::Plain.new }

  subject(:auth) do
    described_class.new(user_store: users, api_key_store: keys, password_hasher: hasher)
  end

  describe "#from_password" do
    it "renvoie une Identity sur email + password corrects" do
      users.create(email: "a@b.c", password_hash: hasher.hash("hunter2"))
      identity = auth.from_password(email: "a@b.c", password: "hunter2")
      expect(identity).not_to be_nil
      expect(identity.user.email).to eq("a@b.c")
      expect(identity.source).to eq(:password)
      # Mode mono-user : tout opérateur authentifié a role :operator.
      expect(identity.role).to eq(:operator)
    end

    it "renvoie nil sur mauvais password" do
      users.create(email: "a@b.c", password_hash: hasher.hash("hunter2"), role: :owner)
      expect(auth.from_password(email: "a@b.c", password: "wrong")).to be_nil
    end

    it "renvoie nil sur user inexistant (sans leak timing)" do
      expect(auth.from_password(email: "nope@x.y", password: "anything")).to be_nil
    end

    it "renvoie nil sur user disabled" do
      user = users.create(email: "a@b.c", password_hash: hasher.hash("p"), role: :owner)
      users.disable!(user.id)
      expect(auth.from_password(email: "a@b.c", password: "p")).to be_nil
    end
  end

  describe "#issue_api_key + #from_authorization" do
    let!(:user) { users.create(email: "a@b.c", password_hash: hasher.hash("p"), role: :owner) }

    it "round trip : la cle issue authentifie son porteur" do
      issued = auth.issue_api_key(user_id: user.id)
      identity = auth.from_authorization("Bearer #{issued[:token]}")
      expect(identity.user.id).to eq(user.id)
      expect(identity.source).to eq(:api_key)
      expect(identity.caller_id).to start_with("key:")
    end

    it "from_authorization renvoie nil sans Bearer" do
      expect(auth.from_authorization(nil)).to be_nil
      expect(auth.from_authorization("")).to be_nil
      expect(auth.from_authorization("Basic abc")).to be_nil
    end

    it "renvoie nil sur token inconnu" do
      expect(auth.from_authorization("Bearer wat")).to be_nil
    end

    it "renvoie nil sur token revoque" do
      issued = auth.issue_api_key(user_id: user.id)
      keys.revoke!(keys.find_by_token(issued[:token]).id)
      expect(auth.from_authorization("Bearer #{issued[:token]}")).to be_nil
    end

    it "renvoie nil quand le user est disabled meme si la cle est encore valide" do
      issued = auth.issue_api_key(user_id: user.id)
      users.disable!(user.id)
      expect(auth.from_authorization("Bearer #{issued[:token]}")).to be_nil
    end
  end

  describe "Argon2id integration (compatibilite avec hasher reel)" do
    let(:hasher) { Reconaut::Auth::PasswordHasher::Argon2id.new(t_cost: 1, m_cost: 8) }

    it "supporte le hash Argon2id complet" do
      users.create(email: "a@b.c", password_hash: hasher.hash("hunter2"), role: :owner)
      identity = auth.from_password(email: "a@b.c", password: "hunter2")
      expect(identity).not_to be_nil
    end
  end
end
