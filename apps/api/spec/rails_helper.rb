# Configuration custom : on permet a la suite request-spec de tourner
# sans Postgres demarre tant que la couche DB n'est pas branchee. Les
# tests qui ont besoin de la DB live se mettent a jour avec
# `pending` / un tag `:db` une fois docker-compose up.
require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

# Skip schema maintenance : aucune migration n'est jouee tant que les
# tests ne ciblent pas la DB (les tests use_cases utilisent in-memory).
# Quand la DB de test sera disponible, retirer ce begin/rescue.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError, ActiveRecord::NoDatabaseError,
       ActiveRecord::ConnectionNotEstablished, PG::ConnectionBad => _
  warn "[rails_helper] DB indisponible - les tests qui en dependent seront skippes."
end

RSpec.configure do |config|
  config.fixture_paths = [Rails.root.join("spec/fixtures")]

  # Pas de transactional fixtures tant qu'on n'a pas de DB cablee : sinon
  # chaque test essaierait d'ouvrir une transaction qui echoue.
  config.use_transactional_fixtures = false

  config.filter_rails_from_backtrace!
end
