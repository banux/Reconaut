# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Active les trois extensions Postgres exigees par project.md :
#   - timescaledb : timeseries de scan
#   - vector (pgvector) : index semantique pour l'agent
#   - age (Apache AGE) : graphe d'actifs
#
# Cf. openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md
#   Requirement: Asset Graph Projection
# Cf. openspec/changes/add-graph-retrieval/tasks.md section 1.1
#
# AGE necessite que la session charge l'extension via LOAD 'age' et que
# le search_path inclue ag_catalog. On le fait via un initializer Rails
# (config/initializers/age.rb) plutot qu'ici, car les sessions d'app
# vivent au-dela de cette migration. Cette migration ne fait que rendre
# l'extension disponible.
class EnableGraphExtensions < ActiveRecord::Migration[8.1]
  def up
    enable_extension "timescaledb"
    enable_extension "vector"
    enable_extension "age"

    # Cree le graphe nomme "reconaut" dans lequel tous les nodes/edges
    # seront materialises. ag_catalog.create_graph est idempotent via
    # WHERE NOT EXISTS pour permettre la re-execution en dev.
    execute <<~SQL
      LOAD 'age';
      SET search_path = ag_catalog, "$user", public;
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'reconaut') THEN
          -- Si le schema "reconaut" traîne d'une tentative précédente
          -- aboutie partiellement, on l'efface — sans ça
          -- create_graph() lève "schema already exists".
          EXECUTE 'DROP SCHEMA IF EXISTS reconaut CASCADE';
          PERFORM ag_catalog.create_graph('reconaut');
        END IF;
      END
      $$;
    SQL
  end

  def down
    execute <<~SQL
      LOAD 'age';
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'reconaut') THEN
          PERFORM ag_catalog.drop_graph('reconaut', true);
        END IF;
      END
      $$;
    SQL

    disable_extension "age"
    disable_extension "vector"
    disable_extension "timescaledb"
  end
end
