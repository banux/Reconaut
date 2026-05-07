# frozen_string_literal: true

# Tests statiques de la migration CreateGraphLabelsAndIndexes.
# Couvre add-graph-retrieval section 1.2.

require "spec_helper"

RSpec.describe "20260507000002_create_graph_labels_and_indexes" do
  let(:source) do
    File.read(File.expand_path(
      "../../../db/migrate/20260507000002_create_graph_labels_and_indexes.rb",
      __dir__
    ))
  end

  it "declare les 8 labels de noeuds requis par add-graph-retrieval section 1.2" do
    %w[Domain Host Service Certificate AutonomousSystem IPRange CPE Vulnerability].each do |label|
      expect(source).to include(label),
                        "label #{label} absent du set declare"
    end
  end

  it "declare les 7 types d'aretes requis par add-graph-retrieval section 1.2" do
    %w[RESOLVES_TO EXPOSES PRESENTS IN_AS IN_RANGE MATCHES_CPE AFFECTED_BY].each do |label|
      expect(source).to include(label)
    end
  end

  it "indexe au minimum host_id, cert sha256, cve_id et domain.name" do
    expect(source).to match(/\["Certificate",\s*"sha256"\]/)
    expect(source).to match(/\["Vulnerability",\s*"cve_id"\]/)
    expect(source).to match(/\["Domain",\s*"name"\]/)
    expect(source).to include("ensure_index(label, \"id\")")
  end

  it "utilise CREATE INDEX IF NOT EXISTS (idempotent)" do
    expect(source).to match(/CREATE INDEX IF NOT EXISTS/)
  end

  it "utilise create_vlabel et create_elabel d'AGE" do
    expect(source).to include("ag_catalog.create_vlabel")
    expect(source).to include("ag_catalog.create_elabel")
  end

  it "ne passe par cypher() pour aucune mutation : uniquement DDL Postgres + DDL AGE" do
    # Le bootstrap des labels et index est du ressort de la couche DDL
    # (create_vlabel, create_elabel, CREATE INDEX). Aucun appel a
    # cypher('reconaut', $$ ... $$) ne doit apparaitre ici - les seules
    # mutations de donnees passent par l'ingestion Rails au runtime.
    expect(source).not_to match(/cypher\s*\(/i)
  end
end
