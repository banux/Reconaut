# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
#   -> Requirement: Recurring job de "lease release"

RSpec.describe LeaseReleaseJob do
  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.connection.execute("SELECT 1")
      @gj_present = ActiveRecord::Base.connection.table_exists?(:good_jobs)
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before(:each) { skip(@skip) if @skip }

  it "no-op gracieux si good_jobs absente" do
    skip "Table good_jobs présente — ce test cible le cas absent" if @gj_present
    expect { described_class.new.perform }.not_to raise_error
  end

  context "avec table good_jobs présente" do
    before do
      skip "Table good_jobs absente" unless @gj_present
      ActiveRecord::Base.connection.execute("DELETE FROM good_jobs")
    end

    def insert(id:, performed_at:, finished_at: nil)
      ActiveRecord::Base.connection.execute(<<~SQL)
        INSERT INTO good_jobs (id, queue_name, serialized_params, created_at, performed_at, finished_at)
        VALUES ('#{id}', 'scan:test', '{}', NOW(),
          #{performed_at ? "'#{performed_at.utc.iso8601}'" : 'NULL'},
          #{finished_at ? "'#{finished_at.utc.iso8601}'" : 'NULL'})
      SQL
    end

    it "remet performed_at à NULL pour les jobs > 5 min sans finished_at" do
      old_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      insert(id: old_id, performed_at: 10.minutes.ago)
      described_class.new.perform
      row = ActiveRecord::Base.connection.execute("SELECT performed_at FROM good_jobs WHERE id='#{old_id}'").to_a.first
      expect(row["performed_at"]).to be_nil
    end

    it "laisse intact un job avec performed_at < 5 min" do
      recent_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      insert(id: recent_id, performed_at: 1.minute.ago)
      described_class.new.perform
      row = ActiveRecord::Base.connection.execute("SELECT performed_at FROM good_jobs WHERE id='#{recent_id}'").to_a.first
      expect(row["performed_at"]).not_to be_nil
    end

    it "laisse intact un job déjà finished" do
      done_id = "cccccccc-cccc-cccc-cccc-cccccccccccc"
      insert(id: done_id, performed_at: 10.minutes.ago, finished_at: 1.minute.ago)
      described_class.new.perform
      row = ActiveRecord::Base.connection.execute("SELECT performed_at FROM good_jobs WHERE id='#{done_id}'").to_a.first
      expect(row["performed_at"]).not_to be_nil
    end
  end
end
