# frozen_string_literal: true

# Cree les labels de noeuds, les types d'aretes et les index AGE
# necessaires aux templates du set noyau.
#
# Source de verite :
#   openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md
#     Requirement: Asset Graph Projection
#   openspec/changes/add-graph-retrieval/tasks.md section 1.2
#
# Conventions :
#   - Tous les noeuds portent une propriete `id` qui sert de clef
#     naturelle (host_id, sha256, cve_id, domain, etc.). On indexe `id`
#     sur chaque label pour rendre les MERGE et les ancrages O(log N).
#   - Les certificats sont indexes aussi par `sha256` (clef dominante
#     pour le template `cert_cluster`).
#   - Les vulnerabilites par `cve_id`, les domaines par `name`.
#   - Le graphe `reconaut` doit avoir ete cree par la migration
#     20260507000001_enable_graph_extensions ; cette migration depend
#     donc d'elle (Rails l'execute dans l'ordre des timestamps).
class CreateGraphLabelsAndIndexes < ActiveRecord::Migration[8.1]
  GRAPH_NAME = "reconaut"

  NODE_LABELS = %w[
    Domain
    Host
    Service
    Certificate
    AutonomousSystem
    IPRange
    CPE
    Vulnerability
    Organization
  ].freeze

  EDGE_LABELS = %w[
    RESOLVES_TO
    EXPOSES
    PRESENTS
    IN_AS
    IN_RANGE
    MATCHES_CPE
    AFFECTED_BY
    OWNS
    PARENT_OF
  ].freeze

  # Index secondaires : (label, propriete). Le couple `id` est ajoute
  # automatiquement pour chaque label.
  SECONDARY_INDEXES = [
    ["Certificate",   "sha256"],
    ["Vulnerability", "cve_id"],
    ["Domain",        "name"],
    ["AutonomousSystem", "number"]
  ].freeze

  def up
    say_with_time "create graph labels" do
      load_age!
      NODE_LABELS.each { |label| ensure_vlabel(label) }
      EDGE_LABELS.each { |label| ensure_elabel(label) }
    end

    say_with_time "create graph indexes" do
      load_age!
      NODE_LABELS.each { |label| ensure_index(label, "id") }
      SECONDARY_INDEXES.each { |label, prop| ensure_index(label, prop) }
    end
  end

  def down
    load_age!
    SECONDARY_INDEXES.each { |label, prop| drop_index(label, prop) }
    NODE_LABELS.each { |label| drop_index(label, "id") }
    # On laisse les labels en place : drop_label dans AGE detruirait toutes
    # les donnees rattachees. Si on veut vraiment redescendre, le down de
    # 20260507000001_enable_graph_extensions drop le graphe entier.
  end

  private

  def load_age!
    execute <<~SQL
      LOAD 'age';
      SET search_path = ag_catalog, "$user", public;
    SQL
  end

  def ensure_vlabel(label)
    execute <<~SQL
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM ag_catalog.ag_label
          WHERE name = '#{label}'
            AND graph = (SELECT graphid FROM ag_catalog.ag_graph WHERE name = '#{GRAPH_NAME}')
        ) THEN
          PERFORM ag_catalog.create_vlabel('#{GRAPH_NAME}', '#{label}');
        END IF;
      END
      $$;
    SQL
  end

  def ensure_elabel(label)
    execute <<~SQL
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM ag_catalog.ag_label
          WHERE name = '#{label}'
            AND graph = (SELECT graphid FROM ag_catalog.ag_graph WHERE name = '#{GRAPH_NAME}')
        ) THEN
          PERFORM ag_catalog.create_elabel('#{GRAPH_NAME}', '#{label}');
        END IF;
      END
      $$;
    SQL
  end

  def ensure_index(label, property)
    index_name = "idx_#{GRAPH_NAME}_#{label.downcase}_#{property}"
    table_name = %("#{GRAPH_NAME}"."#{label}")
    execute <<~SQL
      CREATE INDEX IF NOT EXISTS #{index_name}
        ON #{table_name}
        USING btree (((properties->>'#{property}')));
    SQL
  end

  def drop_index(label, property)
    index_name = "idx_#{GRAPH_NAME}_#{label.downcase}_#{property}"
    execute "DROP INDEX IF EXISTS #{index_name};"
  end
end
