# frozen_string_literal: true

# Tests statiques de la migration CreateGraphRoles.
# Couvre add-graph-retrieval section 1.3.

require "spec_helper"

RSpec.describe "20260507000003_create_graph_roles" do
  let(:source) do
    File.read(File.expand_path(
      "../../../db/migrate/20260507000003_create_graph_roles.rb",
      __dir__
    ))
  end

  it "cree les deux roles writer et reader" do
    expect(source).to include("reconaut_graph_writer")
    expect(source).to include("reconaut_graph_reader")
  end

  it "le reader n'a que SELECT (pas INSERT / UPDATE / DELETE)" do
    # Le seul GRANT mentionnant reader doit etre SELECT.
    reader_grants = source.scan(/GRANT[^;]*reconaut_graph_reader[^;]*/i)
    expect(reader_grants).not_to be_empty

    forbidden = %w[INSERT UPDATE DELETE]
    reader_grants.each do |grant|
      forbidden.each do |verb|
        expect(grant).not_to match(/\b#{verb}\b/i),
                              "reader recoit un grant #{verb} : #{grant.strip}"
      end
    end
  end

  it "le writer recoit INSERT, UPDATE, DELETE (mais ni SUPERUSER ni CREATEDB)" do
    expect(source).to match(/GRANT[^;]*INSERT[^;]*UPDATE[^;]*DELETE[^;]*reconaut_graph_writer/i)
    expect(source).to include("NOSUPERUSER")
    expect(source).to include("NOCREATEDB")
    expect(source).to include("NOCREATEROLE")
  end

  it "revoke create_vlabel/create_elabel/drop_graph en PUBLIC et les redonne au writer" do
    expect(source).to match(/REVOKE EXECUTE ON FUNCTION ag_catalog\.create_vlabel.*FROM PUBLIC/m)
    expect(source).to match(/REVOKE EXECUTE ON FUNCTION ag_catalog\.create_elabel.*FROM PUBLIC/m)
    expect(source).to match(/REVOKE EXECUTE ON FUNCTION ag_catalog\.drop_graph.*FROM PUBLIC/m)
    expect(source).to match(/GRANT EXECUTE ON FUNCTION ag_catalog\.create_vlabel.*TO reconaut_graph_writer/m)
  end

  it "est idempotent (CREATE ROLE garde par IF NOT EXISTS)" do
    expect(source).to match(/IF NOT EXISTS \(SELECT 1 FROM pg_roles/)
  end

  it "fournit un down qui drop les roles" do
    expect(source).to match(/def down/)
    expect(source).to match(/DROP ROLE IF EXISTS reconaut_graph_writer/)
    expect(source).to match(/DROP ROLE IF EXISTS reconaut_graph_reader/)
  end
end
