# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/init-reconaut-platform/tasks.md §6.3.
RSpec.describe AuditLog, type: :model do
  TEST_DB = {
    adapter:  "postgresql", host: "localhost", port: 5432,
    username: "reconaut", password: "reconaut_dev_password",
    database: "reconaut_test", pool: 5
  }.freeze unless defined?(TEST_DB)

  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.establish_connection(TEST_DB)
      ActiveRecord::Base.connection.execute("SELECT 1")
      unless ActiveRecord::Base.connection.table_exists?("audit_log")
        @skip = "Table audit_log absente — lance `RAILS_ENV=test bundle exec rails db:migrate`"
      end
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before(:each) do
    skip(@skip) if @skip
    # Ne PAS faire AuditLog.delete_all : la table est append-only, le
    # DELETE échouera. On utilise TRUNCATE qui contourne le TRIGGER.
    ActiveRecord::Base.connection.execute("TRUNCATE TABLE audit_log RESTART IDENTITY")
  end

  it "INSERT fonctionne (le journal accepte les nouvelles lignes)" do
    entry = AuditLog.create!(
      status: "success", template_id: "mcp:search_hosts",
      params_normalized: { kind: "tcp_probe" }, caller_id: "key:abc",
      duration_ms: 12, nodes_touched: 3
    )
    expect(entry).to be_persisted
    expect(AuditLog.count).to eq(1)
  end

  it "UPDATE direct est rejeté par le TRIGGER (audit_log is append-only)" do
    AuditLog.create!(
      status: "success", template_id: "x", params_normalized: {},
      caller_id: "key:abc"
    )
    expect {
      ActiveRecord::Base.connection.execute(
        "UPDATE audit_log SET caller_id = 'tampered' WHERE caller_id = 'key:abc'"
      )
    }.to raise_error(ActiveRecord::StatementInvalid, /append-only/i)
  end

  it "DELETE direct est rejeté par le TRIGGER" do
    AuditLog.create!(
      status: "success", template_id: "x", params_normalized: {},
      caller_id: "key:abc"
    )
    expect {
      ActiveRecord::Base.connection.execute(
        "DELETE FROM audit_log WHERE caller_id = 'key:abc'"
      )
    }.to raise_error(ActiveRecord::StatementInvalid, /append-only/i)
  end

  it "UPDATE via AR (#update!) est aussi rejeté" do
    entry = AuditLog.create!(
      status: "success", template_id: "x", params_normalized: {},
      caller_id: "key:abc"
    )
    expect { entry.update!(caller_id: "tampered") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/i)
  end

  it "destroy via AR (#destroy) est aussi rejeté" do
    entry = AuditLog.create!(
      status: "success", template_id: "x", params_normalized: {},
      caller_id: "key:abc"
    )
    expect { entry.destroy }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/i)
  end

  it "validations : status doit être dans STATUSES" do
    e = AuditLog.new(status: "lol", caller_id: "x", params_normalized: {})
    expect(e).not_to be_valid
    expect(e.errors[:status]).to be_present
  end
end
