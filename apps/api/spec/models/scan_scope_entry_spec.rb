# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/init-reconaut-platform/tasks.md §2.1.
RSpec.describe ScanScopeEntry, type: :model do
  TEST_DB = {
    adapter:  "postgresql", host: "localhost", port: 5432,
    username: "reconaut", password: "reconaut_dev_password",
    database: "reconaut_test", pool: 5
  }.freeze

  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.establish_connection(TEST_DB)
      ActiveRecord::Base.connection.execute("SELECT 1")
      # Migrer si nécessaire (la table peut ne pas exister dans le
      # test DB tant que la migration n'a pas été jouée côté test).
      unless ActiveRecord::Base.connection.table_exists?("scan_scope_entries")
        @skip = "Table scan_scope_entries absente — lance `RAILS_ENV=test bundle exec rails db:migrate`"
      end
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before(:each) do
    skip(@skip) if @skip
    described_class.delete_all
  end

  describe "validations" do
    let(:base_attrs) {
      { kind: "cidr", value: "192.0.2.0/24", created_by: "key:abc" }
    }

    it "accepte les trois kinds : cidr, domain, host" do
      expect(described_class.new(base_attrs)).to be_valid
      expect(described_class.new(base_attrs.merge(kind: "domain", value: "example.fr"))).to be_valid
      expect(described_class.new(base_attrs.merge(kind: "host", value: "mail.example.fr"))).to be_valid
    end

    it "rejette un kind hors enum" do
      e = described_class.new(base_attrs.merge(kind: "person"))
      expect(e).not_to be_valid
      expect(e.errors[:kind]).to be_present
    end

    it "rejette un CIDR invalide" do
      e = described_class.new(base_attrs.merge(value: "not-a-cidr"))
      expect(e).not_to be_valid
      expect(e.errors[:value].join).to include("CIDR")
    end

    it "rejette un domain avec des caractères interdits" do
      e = described_class.new(base_attrs.merge(kind: "domain", value: "exa mple.fr"))
      expect(e).not_to be_valid
      expect(e.errors[:value].join).to include("DNS")
    end

    it "exige created_by" do
      e = described_class.new(base_attrs.merge(created_by: nil))
      expect(e).not_to be_valid
      expect(e.errors[:created_by]).to be_present
    end
  end

  describe "historisation (append-only)" do
    it "revoke! pose revoked_at sans supprimer la ligne" do
      e = described_class.create!(kind: "cidr", value: "192.0.2.0/24", created_by: "key:abc")
      expect { e.revoke! }.to change { e.reload.revoked_at }.from(nil).to(be_a(Time))
      expect(described_class.count).to eq(1)
    end

    it "revoke! est idempotent : un second appel ne change pas revoked_at" do
      e = described_class.create!(kind: "cidr", value: "192.0.2.0/24", created_by: "key:abc")
      e.revoke!
      first = e.reload.revoked_at
      e.revoke!
      expect(e.reload.revoked_at).to eq(first)
    end

    it "scope `active` exclut les entrées révoquées" do
      a = described_class.create!(kind: "cidr", value: "192.0.2.0/24", created_by: "key:abc")
      b = described_class.create!(kind: "cidr", value: "198.51.100.0/24", created_by: "key:abc")
      b.revoke!

      expect(described_class.active).to contain_exactly(a)
    end
  end

  describe "#covers?" do
    it "cidr couvre une ip à l'intérieur du réseau" do
      e = described_class.create!(kind: "cidr", value: "192.0.2.0/24", created_by: "k")
      expect(e.covers?("ip", "192.0.2.10")).to be true
      expect(e.covers?("ip", "198.51.100.1")).to be false
    end

    it "cidr couvre un sous-réseau plus restreint" do
      e = described_class.create!(kind: "cidr", value: "192.0.2.0/24", created_by: "k")
      expect(e.covers?("cidr", "192.0.2.0/28")).to be true
      expect(e.covers?("cidr", "192.0.0.0/16")).to be false # plus large
    end

    it "domain match exact" do
      e = described_class.create!(kind: "domain", value: "example.fr", created_by: "k")
      expect(e.covers?("domain", "example.fr")).to be true
      expect(e.covers?("domain", "other.fr")).to be false
      # On ne fait PAS de wildcard sur sous-domaines en v1.
      expect(e.covers?("domain", "sub.example.fr")).to be false
    end

    it "host match exact" do
      e = described_class.create!(kind: "host", value: "mail.example.fr", created_by: "k")
      expect(e.covers?("host", "mail.example.fr")).to be true
      expect(e.covers?("host", "www.example.fr")).to be false
    end

    it "ne couvre rien si revoked" do
      e = described_class.create!(kind: "cidr", value: "192.0.2.0/24", created_by: "k")
      e.revoke!
      expect(e.covers?("ip", "192.0.2.10")).to be false
    end
  end
end
