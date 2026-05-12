# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-scanner-pgx-driver/specs/platform/spec.md
#   -> Requirement: Migration scan_results table

RSpec.describe "scan_results table (created by CreateScanResults migration)" do
  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.connection.execute("SELECT 1")
      unless ActiveRecord::Base.connection.table_exists?(:scan_results)
        @skip = "Table scan_results absente — lance `RAILS_ENV=test bundle exec rails db:migrate`"
      end
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before(:each) { skip(@skip) if @skip }

  it "expose les 8 colonnes attendues (6 métier + timestamps)" do
    cols = ActiveRecord::Base.connection.columns(:scan_results).map(&:name)
    expect(cols).to include(
      "idempotency_key", "scan_kind", "target_kind", "target_value",
      "status", "observed_at", "created_at", "updated_at"
    )
  end

  it "idempotency_key est PRIMARY KEY" do
    pk_rows = ActiveRecord::Base.connection.execute(<<~SQL).to_a
      SELECT a.attname
      FROM   pg_index i
      JOIN   pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
      WHERE  i.indrelid = 'scan_results'::regclass
        AND  i.indisprimary
    SQL
    expect(pk_rows.map { |r| r["attname"] }).to eq(["idempotency_key"])
  end

  it "expose les 3 index attendus (scan_kind, target_kind+target_value, observed_at)" do
    indexes = ActiveRecord::Base.connection.indexes(:scan_results).map(&:name)
    expect(indexes).to include(
      a_string_matching(/scan_kind/),
      a_string_matching(/target_kind/),
      a_string_matching(/observed_at/)
    )
  end

  it "accepte INSERT ... ON CONFLICT (idempotency_key) DO NOTHING" do
    sql = <<~SQL
      INSERT INTO scan_results (idempotency_key, scan_kind, target_kind, target_value, status, observed_at)
      VALUES ('k-test-1', 'dns_records', 'domain', 'example.fr', 'ok', NOW())
      ON CONFLICT (idempotency_key) DO NOTHING
    SQL
    expect { ActiveRecord::Base.connection.execute(sql) }.not_to raise_error
    expect { ActiveRecord::Base.connection.execute(sql) }.not_to raise_error

    rows = ActiveRecord::Base.connection.execute(
      "SELECT COUNT(*) AS c FROM scan_results WHERE idempotency_key='k-test-1'"
    ).to_a
    expect(rows.first["c"]).to eq(1)
  ensure
    ActiveRecord::Base.connection.execute("DELETE FROM scan_results WHERE idempotency_key='k-test-1'")
  end

  it "rejette idempotency_key NULL (NOT NULL contraint)" do
    expect {
      ActiveRecord::Base.connection.execute(<<~SQL)
        INSERT INTO scan_results (idempotency_key, scan_kind, target_kind, target_value, status, observed_at)
        VALUES (NULL, 'k', 'h', 'v', 'ok', NOW())
      SQL
    }.to raise_error(ActiveRecord::NotNullViolation, /idempotency_key/)
  end

  it "n'est PAS une hypertable Timescale en v1" do
    rows = ActiveRecord::Base.connection.execute(<<~SQL).to_a
      SELECT 1
      FROM timescaledb_information.hypertables
      WHERE hypertable_name = 'scan_results'
    SQL
    expect(rows).to be_empty
  end
end
