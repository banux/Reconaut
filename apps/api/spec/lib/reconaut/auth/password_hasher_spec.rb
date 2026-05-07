# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../app/lib/reconaut/auth/password_hasher"

RSpec.describe Reconaut::Auth::PasswordHasher do
  describe Reconaut::Auth::PasswordHasher::Argon2id do
    # Argon2 est volontairement couteux ; on parametre cost minimum
    # pour rester < 200 ms par hash en CI. m_cost=8 (=256 KiB) reste
    # bien au-dessus du minimum gem Argon2 mais bien en dessous des
    # 64 MiB du profil interactif RFC9106.
    subject(:hasher) { described_class.new(t_cost: 1, m_cost: 8) }

    it "hash != mot de passe en clair" do
      h = hasher.hash("hunter2")
      expect(h).not_to eq("hunter2")
      expect(h).to start_with("$argon2id$")
    end

    it "verify(password, hash) -> true" do
      h = hasher.hash("hunter2")
      expect(hasher.verify("hunter2", h)).to be true
    end

    it "verify avec un mauvais password -> false" do
      h = hasher.hash("hunter2")
      expect(hasher.verify("wrong", h)).to be false
    end

    it "deux hashes du meme password sont differents (sel)" do
      a = hasher.hash("hunter2")
      b = hasher.hash("hunter2")
      expect(a).not_to eq(b)
      expect(hasher.verify("hunter2", a)).to be true
      expect(hasher.verify("hunter2", b)).to be true
    end

    it "rejette un password vide" do
      expect { hasher.hash("") }.to raise_error(ArgumentError)
    end

    it "verify renvoie false plutot que de lever sur un hash vide" do
      expect(hasher.verify("anything", "")).to be false
    end

    it "verify leve InvalidHashError sur un hash mal forme" do
      expect {
        hasher.verify("anything", "not-an-argon2-hash")
      }.to raise_error(Reconaut::Auth::PasswordHasher::InvalidHashError)
    end
  end

  describe Reconaut::Auth::PasswordHasher::Plain do
    subject(:hasher) { described_class.new }

    it "round trip basique" do
      h = hasher.hash("x")
      expect(hasher.verify("x", h)).to be true
      expect(hasher.verify("y", h)).to be false
    end
  end
end
