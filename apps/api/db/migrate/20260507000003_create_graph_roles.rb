# frozen_string_literal: true

# Cree deux roles Postgres distincts pour la couche graphe :
#
#   - reconaut_graph_writer : utilise par l'ingestion Rails pour MERGE
#     les noeuds et aretes. A le droit INSERT/UPDATE/DELETE sur les
#     tables de labels AGE du graphe `reconaut`.
#   - reconaut_graph_reader : utilise par l'execution des templates de
#     l'agent. SELECT uniquement, AUCUN privilege d'ecriture.
#
# Source de verite :
#   openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md
#     Requirement: Parameterized Read-Only Query Templates
#       -> Scenario "Role Postgres restreint a la lecture"
#   openspec/changes/add-graph-retrieval/tasks.md section 1.3
#
# Le mot de passe initial est volontairement non defini : un superuser
# le pose via `ALTER ROLE ... WITH PASSWORD '...'` dans la phase de
# bootstrap operationnel. Les deux roles sont LOGIN, NOSUPERUSER,
# NOCREATEDB, NOCREATEROLE.
class CreateGraphRoles < ActiveRecord::Migration[8.1]
  def up
    # Creation idempotente des deux roles.
    execute <<~SQL
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconaut_graph_writer') THEN
          CREATE ROLE reconaut_graph_writer
            LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconaut_graph_reader') THEN
          CREATE ROLE reconaut_graph_reader
            LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
        END IF;
      END
      $$;
    SQL

    # Acces au catalog AGE.
    execute <<~SQL
      GRANT USAGE ON SCHEMA ag_catalog TO reconaut_graph_writer, reconaut_graph_reader;
      GRANT SELECT ON ALL TABLES IN SCHEMA ag_catalog
        TO reconaut_graph_writer, reconaut_graph_reader;
    SQL

    # Acces au schema du graphe lui-meme. Les tables de labels vivent
    # dans un schema homonyme du graphe (cree par create_graph).
    execute <<~SQL
      GRANT USAGE ON SCHEMA "reconaut"
        TO reconaut_graph_writer, reconaut_graph_reader;
      GRANT SELECT ON ALL TABLES IN SCHEMA "reconaut"
        TO reconaut_graph_reader;
      GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "reconaut"
        TO reconaut_graph_writer;
    SQL

    # Defaut pour les futures tables de labels crees par AGE
    # (create_vlabel / create_elabel materialisent une table par label).
    execute <<~SQL
      ALTER DEFAULT PRIVILEGES IN SCHEMA "reconaut"
        GRANT SELECT ON TABLES TO reconaut_graph_reader;
      ALTER DEFAULT PRIVILEGES IN SCHEMA "reconaut"
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO reconaut_graph_writer;
    SQL

    # Le reader ne doit JAMAIS executer une fonction qui muterait le
    # graphe. AGE expose les operations mutantes via cypher() et
    # create_vlabel/create_elabel/drop_graph. Le garde-fou applicatif est
    # le linter (assert_read_only!) ; ici on ajoute le filet Postgres.
    execute <<~SQL
      REVOKE EXECUTE ON FUNCTION ag_catalog.create_vlabel(name, name) FROM PUBLIC;
      REVOKE EXECUTE ON FUNCTION ag_catalog.create_elabel(name, name) FROM PUBLIC;
      REVOKE EXECUTE ON FUNCTION ag_catalog.drop_graph(name, boolean) FROM PUBLIC;
      GRANT EXECUTE ON FUNCTION ag_catalog.create_vlabel(name, name)
        TO reconaut_graph_writer;
      GRANT EXECUTE ON FUNCTION ag_catalog.create_elabel(name, name)
        TO reconaut_graph_writer;
    SQL
  end

  def down
    execute <<~SQL
      DROP ROLE IF EXISTS reconaut_graph_writer;
      DROP ROLE IF EXISTS reconaut_graph_reader;
    SQL
  end
end
