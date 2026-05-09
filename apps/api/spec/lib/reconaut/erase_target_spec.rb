# frozen_string_literal: true

require "rails_helper"
require "digest"

# Cf. openspec/changes/init-reconaut-platform/tasks.md §6.2 (reformulé
# par drop-gdpr-framing) et add-graph-retrieval §6.1/§6.2.
RSpec.describe Reconaut::EraseTarget do
  TEST_DB = {
    adapter:  "postgresql", host: "localhost", port: 5432,
    username: "reconaut", password: "reconaut_dev_password",
    database: "reconaut_test", pool: 5
  }.freeze unless defined?(TEST_DB)

  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.establish_connection(TEST_DB)
      conn = ActiveRecord::Base.connection
      conn.execute("SELECT 1")
      conn.execute("CREATE EXTENSION IF NOT EXISTS age")
      conn.execute(<<~SQL)
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'reconaut') THEN
            EXECUTE 'DROP SCHEMA IF EXISTS reconaut CASCADE';
            PERFORM ag_catalog.create_graph('reconaut');
          END IF;
        END
        $$;
      SQL
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before(:each) do
    skip(@skip) if @skip

    conn = ActiveRecord::Base.connection
    conn.execute(%q[LOAD 'age'; SET search_path = ag_catalog, "$user", public;])
    conn.execute(<<~SQL)
      SELECT * FROM cypher('reconaut', $$
        MATCH (n) DETACH DELETE n
      $$) AS (n agtype);
    SQL
    Service.delete_all if defined?(Service) && Service.table_exists?
    Scan.delete_all if defined?(Scan) && Scan.table_exists?
    Host.delete_all if defined?(Host) && Host.table_exists?
  end

  let(:conn) { ActiveRecord::Base.connection }

  def count_graph_nodes
    rows = conn.execute(<<~SQL).to_a
      SELECT * FROM cypher('reconaut', $$
        MATCH (n) RETURN count(n) AS c
      $$) AS (c agtype);
    SQL
    rows.first["c"].to_i
  end

  it "efface un host par fqdn et tout son graphe associé" do
    h = Host.create!(fqdn: "h1.example.fr")
    Service.create!(host: h, port: 22, protocol: "tcp", outcome: "success", scanned_at: Time.now.utc)
    Reconaut::GraphProjector.call(payload: {
      "schema_version" => 1, "job_id" => "j", "idempotency_key" => "k1234567",
      "target" => { "kind" => "host", "value" => "h1.example.fr" },
      "status" => "success", "observed_at" => "2026-05-09T12:00:00Z",
      "findings" => [
        { "port" => 22, "protocol" => "tcp" },
        { "port" => 443, "protocol" => "tcp", "tls_cert_sha256" => "ABCD" }
      ]
    })

    expect(Host.count).to eq(1)
    expect(Service.count).to eq(1)
    expect(count_graph_nodes).to be > 0

    result = described_class.call(target: "h1.example.fr")

    expect(result.hosts_deleted).to eq(1)
    expect(Host.count).to eq(0)
    # Cascade FK supprime les services scalaires.
    expect(Service.count).to eq(0)
    # Le graphe ne contient plus de nœud porté par h1.
    rows = conn.execute(<<~SQL).to_a
      SELECT * FROM cypher('reconaut', $$
        MATCH (n) WHERE n.id = 'h1.example.fr' OR n.host_id = 'h1.example.fr'
        RETURN count(n) AS c
      $$) AS (c agtype);
    SQL
    expect(rows.first["c"].to_i).to eq(0)
  end

  it "efface un domain et son nœud Domain dans le graphe" do
    Reconaut::GraphProjector.call(payload: {
      "schema_version" => 1, "job_id" => "j2", "idempotency_key" => "k2345678",
      "target" => { "kind" => "domain", "value" => "example.fr" },
      "status" => "success", "observed_at" => "2026-05-09T12:00:00Z",
      "findings" => [
        { "record_type" => "A", "name" => "example.fr", "value" => "192.0.2.10", "ttl" => 300 }
      ]
    })

    described_class.call(target: "example.fr")

    rows = conn.execute(<<~SQL).to_a
      SELECT * FROM cypher('reconaut', $$
        MATCH (n) WHERE n.name = 'example.fr' OR n.id = 'example.fr'
        RETURN count(n) AS c
      $$) AS (c agtype);
    SQL
    expect(rows.first["c"].to_i).to eq(0)
  end

  it "rollback sur erreur : aucun changement persisté" do
    h = Host.create!(fqdn: "rollback.example.fr")
    Reconaut::GraphProjector.call(payload: {
      "schema_version" => 1, "job_id" => "j3", "idempotency_key" => "k3456789",
      "target" => { "kind" => "host", "value" => "rollback.example.fr" },
      "status" => "success", "observed_at" => "2026-05-09T12:00:00Z",
      "findings" => [{ "port" => 80, "protocol" => "tcp" }]
    })

    initial_hosts  = Host.count
    initial_nodes  = count_graph_nodes

    # Force une erreur via stub : la suppression Cypher du graphe lève
    # une StandardError, ce qui doit rollbacker la transaction entière.
    allow(described_class).to receive(:delete_graph_nodes!).and_raise(StandardError, "simulated")

    expect {
      described_class.call(target: "rollback.example.fr")
    }.to raise_error(StandardError, /simulated/)

    expect(Host.count).to eq(initial_hosts)
    expect(count_graph_nodes).to eq(initial_nodes)
  end

  it "ligne d'audit avec target_hash sha256 et compte d'objets" do
    Host.create!(fqdn: "audit.example.fr")

    audit = Class.new {
      def initialize; @entries = []; end
      attr_reader :entries
      def record(**fields); @entries << fields; end
    }.new

    described_class.call(
      target:          "audit.example.fr",
      audit_recorder:  audit,
      caller_id:       "key:abc"
    )

    expect(audit.entries.size).to eq(1)
    entry = audit.entries.first
    expect(entry[:status]).to eq(:success)
    expect(entry[:template_id]).to eq("erase_target")
    expect(entry[:caller_id]).to eq("key:abc")
    expect(entry[:params_normalized][:action]).to eq("erase")
    expected_hash = Digest::SHA256.hexdigest("audit.example.fr")
    expect(entry[:params_normalized][:target_hash]).to eq(expected_hash)
    expect(entry[:params_normalized][:hosts_deleted]).to eq(1)
  end

  it "rejette une cible vide" do
    expect { described_class.call(target: "") }.to raise_error(ArgumentError)
    expect { described_class.call(target: "  ") }.to raise_error(ArgumentError)
  end
end
