# frozen_string_literal: true

# Tests statiques de la migration EnableGraphExtensions.
#
# Le test d'integration end-to-end qui execute reellement la migration
# contre une base Postgres avec AGE installe (cf. ops/postgres/Dockerfile)
# est dans spec/integration/graph_extensions_spec.rb (gate sur
# DATABASE_INTEGRATION_TESTS=1) - hors scope de la suite par defaut tant
# que docker-compose n'est pas demarre dans la CI locale.
#
# Couvre add-graph-retrieval tasks 1.1.

require "spec_helper"

RSpec.describe "20260507000001_enable_graph_extensions" do
  let(:migration_path) do
    File.expand_path(
      "../../../db/migrate/20260507000001_enable_graph_extensions.rb",
      __dir__
    )
  end
  let(:source) { File.read(migration_path) }

  it "le fichier existe" do
    expect(File).to exist(migration_path)
  end

  it "active les trois extensions exigees par project.md" do
    expect(source).to match(/enable_extension\s+"timescaledb"/)
    expect(source).to match(/enable_extension\s+"vector"/)
    expect(source).to match(/enable_extension\s+"age"/)
  end

  it "cree un graphe AGE nomme 'reconaut'" do
    expect(source).to match(/create_graph\('reconaut'\)/)
  end

  it "definit aussi un down (reversible)" do
    expect(source).to match(/def down/)
    expect(source).to match(/disable_extension\s+"age"/)
  end

  it "est idempotent : la creation de graphe est gardee par un IF NOT EXISTS" do
    expect(source).to match(/IF NOT EXISTS \(SELECT 1 FROM ag_catalog\.ag_graph WHERE name = 'reconaut'\)/)
  end

  it "est nomme avec un prefixe de timestamp standard Rails" do
    base = File.basename(migration_path)
    expect(base).to match(/\A\d{14}_/)
  end
end
