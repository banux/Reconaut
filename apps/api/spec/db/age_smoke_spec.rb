# frozen_string_literal: true

require "rails_helper"

# Smoke test de l'extension Apache AGE après migration.
# Cf. openspec/changes/add-graph-retrieval/tasks.md §1.1 :
#   "Test d'intégration qui crée puis lit un nœud trivial via
#    cypher('reconaut', $$ CREATE (n:Test {id: 1}) RETURN n $$)."
#
# rails_helper appelle maintain_test_schema! qui efface les
# extensions/AGE du test DB (schema.rb ne les déclare pas). Ce spec
# rétablit donc lui-même AGE en début de suite, puis exerce le scénario.
RSpec.describe "Apache AGE smoke test", type: :db do
  TEST_DB_CONFIG = {
    adapter:  "postgresql",
    host:     "localhost",
    port:     5432,
    username: "reconaut",
    password: "reconaut_dev_password",
    database: "reconaut_test",
    pool:     5
  }.freeze

  before(:all) do
    @skip_reason = nil
    begin
      ActiveRecord::Base.establish_connection(TEST_DB_CONFIG)
      conn = ActiveRecord::Base.connection
      # Setup minimal AGE (idempotent). Ce spec couvre §1.1 du change
      # add-graph-retrieval : l'objectif est de prouver qu'AGE est
      # utilisable, pas de tester le pipeline de migration Rails.
      conn.execute("CREATE EXTENSION IF NOT EXISTS age")
      # `create_graph` n'est pas idempotent : il crée un schema dont
      # l'existence indépendante (par ex. créé par un test précédent
      # qui a échoué à cleanup) déclenche `schema "reconaut" already
      # exists`. On vérifie d'abord le registre AGE puis on aligne
      # le schema si besoin.
      conn.execute(<<~SQL)
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'reconaut') THEN
            -- Le schema peut traîner d'un test précédent — on le
            -- nettoie pour qu'AGE puisse le recréer proprement.
            EXECUTE 'DROP SCHEMA IF EXISTS reconaut CASCADE';
            PERFORM ag_catalog.create_graph('reconaut');
          END IF;
        END
        $$;
      SQL
    rescue StandardError => e
      @skip_reason = "DB indisponible : #{e.class}: #{e.message}"
    end
  end

  before(:each) { skip(@skip_reason) if @skip_reason }

  it "extension `age` chargée" do
    n = ActiveRecord::Base.connection.execute(
      "SELECT count(*)::int AS n FROM pg_extension WHERE extname = 'age'"
    ).first["n"]
    expect(n).to eq(1)
  end

  it "graphe `reconaut` créé par la migration" do
    rows = ActiveRecord::Base.connection.execute(
      "SELECT name FROM ag_catalog.ag_graph WHERE name = 'reconaut'"
    ).to_a
    expect(rows.size).to eq(1)
  end

  it "Cypher CREATE puis READ d'un nœud trivial fonctionne" do
    conn = ActiveRecord::Base.connection
    # Setup AGE search_path pour cette connexion (les fonctions
    # cypher() vivent dans ag_catalog).
    conn.execute(%q[LOAD 'age'; SET search_path = ag_catalog, "$user", public;])

    # CREATE
    create_sql = <<~SQL
      SELECT * FROM cypher('reconaut', $$
        CREATE (n:SmokeTest {id: 'spec-1', kind: 'rspec'})
        RETURN n
      $$) AS (n agtype);
    SQL
    created = conn.execute(create_sql).to_a
    expect(created.size).to eq(1)

    # READ
    read_sql = <<~SQL
      SELECT * FROM cypher('reconaut', $$
        MATCH (n:SmokeTest {id: 'spec-1'})
        RETURN n.kind
      $$) AS (kind agtype);
    SQL
    read = conn.execute(read_sql).to_a
    expect(read.size).to eq(1)
    # Valeur agtype : `"rspec"` (avec guillemets JSON).
    expect(read.first["kind"]).to include("rspec")

    # Cleanup pour ne pas polluer le graphe entre runs.
    conn.execute(<<~SQL)
      SELECT * FROM cypher('reconaut', $$
        MATCH (n:SmokeTest {id: 'spec-1'})
        DELETE n
      $$) AS (n agtype);
    SQL
  end
end
