# Configuration custom : on permet a la suite request-spec de tourner
# sans Postgres demarre tant que la couche DB n'est pas branchee. Les
# tests qui ont besoin de la DB live se mettent a jour avec
# `pending` / un tag `:db` une fois docker-compose up.
require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
# Posture TLS par défaut en test : permet le trafic en clair via
# Rack::Test pour ne pas forcer chaque request spec à injecter
# `X-Forwarded-Proto: https`. Les specs qui valident l'enforcement
# TLS (`spec/requests/mcp/tls_posture_spec.rb`) overrident cette
# valeur via `around { |ex| ENV[...] = "..." }`.
ENV["RECONAUT_MCP_TLS_REQUIRED"] ||= "false"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

# Schema maintenance : on évite `maintain_test_schema!` parce qu'il
# tente de charger schema.rb, qui ne représente pas encore les tables
# AGE (ag_catalog). À la place, on joue les migrations explicitement ;
# si la DB est indisponible, on warn et les specs DB-bound se skippent
# individuellement.
begin
  ActiveRecord::Base.connection.execute("SELECT 1")
  was_verbose = ActiveRecord::Migration.verbose
  ActiveRecord::Migration.verbose = false
  ActiveRecord::Tasks::DatabaseTasks.migrate
  ActiveRecord::Migration.verbose = was_verbose
rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished,
       PG::ConnectionBad => _
  warn "[rails_helper] DB indisponible - les tests qui en dependent seront skippes."
rescue StandardError => e
  warn "[rails_helper] migration test DB a échoué : #{e.class}: #{e.message}"
end

Dir[Rails.root.join("spec/support/**/*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.fixture_paths = [Rails.root.join("spec/fixtures")]

  # Pas de transactional fixtures tant qu'on n'a pas de DB cablee : sinon
  # chaque test essaierait d'ouvrir une transaction qui echoue.
  config.use_transactional_fixtures = false

  # Nettoyage des tables d'auth entre chaque example. Avant
  # `add-persistent-auth-storage`, le store user/api_key était in-memory
  # et reset par `Registry.reset!` ; depuis le switch vers ActiveRecord,
  # l'état persiste en base et peut polluer les examples suivants.
  config.before(:each) do
    if defined?(::Reconaut::Auth::ArApiKey) &&
       ActiveRecord::Base.connection.table_exists?(:api_keys)
      ::Reconaut::Auth::ArApiKey.delete_all
      ::Reconaut::Auth::ArUser.delete_all
    end
  rescue ActiveRecord::ActiveRecordError, PG::Error
    # Suite tournant sans DB cablée : on ignore.
  end

  config.filter_rails_from_backtrace!
end
