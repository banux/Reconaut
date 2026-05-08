# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/init-reconaut-platform/tasks.md §2.1 :
#   "spec/models/host_spec.rb assure que l'hypertable est créée et
#    qu'une politique de rétention 90 jours est attachée."
RSpec.describe Host, type: :model do
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
      unless ActiveRecord::Base.connection.table_exists?("hosts") &&
             ActiveRecord::Base.connection.table_exists?("services")
        @skip = "Tables hosts/services absentes — lance `RAILS_ENV=test bundle exec rails db:migrate`"
      end
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before(:each) do
    skip(@skip) if @skip
    Service.delete_all if defined?(Service) && Service.table_exists?
    Host.delete_all
  end

  describe "validations" do
    it "accepte un host avec uniquement une ip" do
      h = described_class.new(ip: "192.0.2.10")
      expect(h).to be_valid
    end

    it "accepte un host avec uniquement un fqdn" do
      h = described_class.new(fqdn: "example.fr")
      expect(h).to be_valid
    end

    it "accepte un host avec ip + fqdn" do
      h = described_class.new(ip: "192.0.2.10", fqdn: "example.fr")
      expect(h).to be_valid
    end

    it "rejette un host sans ip ni fqdn" do
      h = described_class.new
      expect(h).not_to be_valid
      expect(h.errors[:base].join).to include("at least one of ip or fqdn")
    end
  end

  describe "TimescaleDB hypertable sur services" do
    it "services est déclaré comme hypertable" do
      rows = ActiveRecord::Base.connection.execute(<<~SQL).to_a
        SELECT hypertable_name
        FROM timescaledb_information.hypertables
        WHERE hypertable_name = 'services'
      SQL
      expect(rows.size).to eq(1)
    end

    it "le partitionnement est sur scanned_at" do
      rows = ActiveRecord::Base.connection.execute(<<~SQL).to_a
        SELECT column_name
        FROM timescaledb_information.dimensions
        WHERE hypertable_name = 'services'
      SQL
      expect(rows.first["column_name"]).to eq("scanned_at")
    end

    it "une politique de rétention de 90 jours est attachée à services" do
      rows = ActiveRecord::Base.connection.execute(<<~SQL).to_a
        SELECT config
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_retention'
          AND hypertable_name = 'services'
      SQL
      expect(rows.size).to eq(1)
      # Le config est un jsonb : { "drop_after": "P90D", ... } (ISO 8601).
      cfg = JSON.parse(rows.first["config"])
      expect(cfg["drop_after"]).to eq("P90D")
    end
  end

  describe "Service association" do
    it "destroy d'un host cascade sur ses services" do
      h = described_class.create!(ip: "192.0.2.10")
      Service.create!(
        host: h, port: 22, protocol: "tcp", outcome: "success",
        scanned_at: Time.now.utc
      )
      expect { h.destroy }.to change { Service.count }.by(-1)
    end
  end
end
