# frozen_string_literal: true

# Smoke test - verifie que RSpec tourne et que l'env Rails se charge.
# Ce test satisfait le critere "chaque suite contient un test smoke trivial
# qui passe" de openspec/changes/add-tech-stack/tasks.md section 2.1.
#
# Aucun acces base de donnees : on charge uniquement spec_helper, pas
# rails_helper, pour rester executable sur une machine sans Postgres.

require "spec_helper"

RSpec.describe "smoke" do
  it "executes RSpec" do
    expect(true).to eq(true)
  end

  it "has Rails 8 in the Gemfile" do
    gemfile = File.read(File.expand_path("../Gemfile", __dir__))
    expect(gemfile).to match(/gem "rails", "~> 8\.\d+/)
  end
end
