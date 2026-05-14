# frozen_string_literal: true

require "rails_helper"

# Cf. openspec/changes/add-good-job-cron-config/specs/platform/spec.md
#   -> Requirement: GoodJob cron schedule `lease_release` active

RSpec.describe "GoodJob initializer configuration" do
  let(:cfg) { Rails.application.config.good_job }

  describe "cron schedule" do
    it "contient une entrée `lease_release` pointant sur LeaseReleaseJob, chaque minute" do
      cron = cfg.cron
      entry = cron[:lease_release] || cron["lease_release"]
      expect(entry).not_to be_nil
      expect(entry[:class] || entry["class"]).to eq("LeaseReleaseJob")
      expect(entry[:cron] || entry["cron"]).to eq("* * * * *")
      description = entry[:description] || entry["description"]
      expect(description).to be_a(String)
      expect(description).not_to be_empty
    end
  end

  describe "tuning sane" do
    it "poll_interval = 5 (secondes)" do
      expect(cfg.poll_interval).to eq(5)
    end

    it "preserve_job_records = false (pas d'archive en v1)" do
      expect(cfg.preserve_job_records).to be false
    end
  end

  describe "execution_mode" do
    it "n'est PAS forcé en :async en environnement test (queue_adapter :test reste prioritaire)" do
      # L'initializer skip la ligne `execution_mode = :async` quand
      # Rails.env.test?. Donc en test, la valeur reste nil (default
      # implicite) ET le queue_adapter ActiveJob est :test.
      expect(cfg.execution_mode).to be_nil
      expect(ActiveJob::Base.queue_adapter.class.name).to eq("ActiveJob::QueueAdapters::TestAdapter")
    end

    it "serait :async en dev/prod (vérifié dans un test runner direct)" do
      # Ce qu'on vérifie ici : la ligne d'init est gatée par `unless
      # Rails.env.test?`. La vérif runtime dev/prod se fait via un
      # `bundle exec rails runner -e development` documenté dans
      # tasks.md §1.1, pas testable en rspec (qui tourne en :test).
      #
      # On peut au moins relire l'initializer pour confirmer la garde.
      content = File.read(Rails.root.join("config/initializers/good_job.rb"))
      expect(content).to match(/unless Rails\.env\.test\?/)
      expect(content).to include(":async")
    end
  end
end
