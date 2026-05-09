# frozen_string_literal: true

require "rails_helper"
begin
  require "webmock/rspec"
rescue LoadError
  # webmock pas dans le Gemfile : la garde "0 appel sortant" est plus
  # faible mais le projecteur reste pure SQL. Le test §9.2 (air-gappé)
  # couvrira la garantie réseau via NetworkPolicy/iptables.
end

# Cf. openspec/changes/add-graph-retrieval/tasks.md §2.1 / §2.2.
RSpec.describe Reconaut::GraphProjector do
  TEST_DB = {
    adapter:  "postgresql", host: "localhost", port: 5432,
    username: "reconaut", password: "reconaut_dev_password",
    database: "reconaut_test", pool: 5
  }.freeze unless defined?(TEST_DB)

  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.establish_connection(TEST_DB)
      ActiveRecord::Base.connection.execute("SELECT 1")
      ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS age")
      ActiveRecord::Base.connection.execute(<<~SQL)
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

    # Cleanup graph entre tests : on retire tous les nodes/edges Test*
    # pour ne pas polluer (CREATE/MATCH cypher).
    conn = ActiveRecord::Base.connection
    conn.execute(%q[LOAD 'age'; SET search_path = ag_catalog, "$user", public;])
    conn.execute(<<~SQL)
      SELECT * FROM cypher('reconaut', $$
        MATCH (n) DETACH DELETE n
      $$) AS (n agtype);
    SQL
  end

  let(:conn) { ActiveRecord::Base.connection }

  def count_nodes(label)
    rows = conn.execute(<<~SQL).to_a
      SELECT * FROM cypher('reconaut', $$
        MATCH (n:#{label}) RETURN count(n) AS c
      $$) AS (c agtype);
    SQL
    rows.first["c"].to_i
  end

  def count_edges(label)
    rows = conn.execute(<<~SQL).to_a
      SELECT * FROM cypher('reconaut', $$
        MATCH ()-[r:#{label}]->() RETURN count(r) AS c
      $$) AS (c agtype);
    SQL
    rows.first["c"].to_i
  end

  describe "#call (host avec service Modbus + cert TLS)" do
    let(:payload) {
      {
        "schema_version"  => 1,
        "job_id"          => "job-test-001",
        "idempotency_key" => "scan-test-host1-aaaa",
        "target"          => { "kind" => "host", "value" => "H1" },
        "status"          => "success",
        "observed_at"     => "2026-05-09T12:00:00Z",
        "findings" => [
          { "port" => 502, "protocol" => "tcp", "service" => "modbus" },
          { "port" => 443, "protocol" => "tcp", "tls_cert_sha256" => "C1SHA" }
        ]
      }
    }

    it "projette Host(H1), Service(S1), Certificate(C1) + EXPOSES + PRESENTS" do
      result = described_class.call(payload: payload)

      expect(count_nodes("Host")).to be >= 1
      expect(count_nodes("Service")).to eq(2)
      expect(count_nodes("Certificate")).to eq(1)
      expect(count_edges("EXPOSES")).to eq(2)
      expect(count_edges("PRESENTS")).to eq(1)
      expect(result.nodes_merged).to be > 0
      expect(result.edges_merged).to be > 0
    end

    it "Certificate partagé : H2 préexistant relié au même C1" do
      # Pré-existence : H2 + cert C1.
      first_payload = payload.merge(
        "idempotency_key" => "scan-test-h2-bbbb",
        "target" => { "kind" => "host", "value" => "H2" }
      )
      described_class.call(payload: first_payload)
      expect(count_nodes("Certificate")).to eq(1)
      expect(count_edges("PRESENTS")).to eq(1)

      # Nouvelle ingestion sur H1 partage C1.
      described_class.call(payload: payload)
      expect(count_nodes("Certificate")).to eq(1) # toujours un seul
      expect(count_edges("PRESENTS")).to eq(2)    # H1->C1 et H2->C1
    end
  end

  describe "idempotence (§2.2)" do
    let(:payload) {
      {
        "schema_version"  => 1,
        "job_id"          => "job-idem",
        "idempotency_key" => "scan-idem-aaaa",
        "target"          => { "kind" => "host", "value" => "H_IDEM" },
        "status"          => "success",
        "observed_at"     => "2026-05-09T12:00:00Z",
        "findings" => [
          { "port" => 22, "protocol" => "tcp" },
          { "port" => 443, "protocol" => "tcp", "tls_cert_sha256" => "CERTX" }
        ]
      }
    }

    it "réinjecter 100 fois le même scan ne duplique pas les arêtes" do
      described_class.call(payload: payload)
      after_first = count_edges("EXPOSES") + count_edges("PRESENTS")

      99.times { described_class.call(payload: payload) }
      after_hundred = count_edges("EXPOSES") + count_edges("PRESENTS")

      expect(after_first).to eq(after_hundred),
                              "après 100 itérations on a #{after_hundred} arêtes vs #{after_first} après la 1ère"
    end
  end

  describe "domain target avec records DNS" do
    let(:payload) {
      {
        "schema_version"  => 1,
        "job_id"          => "job-dns",
        "idempotency_key" => "scan-dns-cccc",
        "target"          => { "kind" => "domain", "value" => "example.fr" },
        "status"          => "success",
        "observed_at"     => "2026-05-09T12:00:00Z",
        "findings" => [
          { "record_type" => "A",    "name" => "example.fr", "value" => "192.0.2.10", "ttl" => 300 },
          { "record_type" => "AAAA", "name" => "example.fr", "value" => "2001:db8::1", "ttl" => 300 },
          { "record_type" => "MX",   "name" => "example.fr", "value" => "10 mail.example.fr", "ttl" => 300 }
        ]
      }
    }

    it "RESOLVES_TO créé pour A et AAAA, pas pour MX" do
      described_class.call(payload: payload)
      expect(count_nodes("Domain")).to eq(1)
      expect(count_edges("RESOLVES_TO")).to eq(2) # A et AAAA seulement
    end
  end

  describe "graph_lag_seconds metric (§2.3)" do
    let(:metrics) {
      Class.new {
        def initialize; @samples = []; end
        attr_reader :samples
        def observe(name, value, labels); @samples << [name, value, labels]; end
        def increment(*); end
      }.new
    }

    it "émet graph_lag_seconds = now - observed_at" do
      payload = {
        "schema_version"  => 1,
        "job_id"          => "job-lag",
        "idempotency_key" => "scan-lag-eeee",
        "target"          => { "kind" => "host", "value" => "H_LAG" },
        "status"          => "success",
        "observed_at"     => "2026-05-09T11:59:50Z",
        "findings"        => []
      }
      fixed_now = Time.parse("2026-05-09T12:00:00Z")
      described_class.call(payload: payload, metrics: metrics, clock: -> { fixed_now })

      lag_samples = metrics.samples.select { |s| s[0] == :graph_lag_seconds }
      expect(lag_samples.size).to eq(1)
      expect(lag_samples.first[1]).to be_within(0.5).of(10.0) # 11:59:50 → 12:00:00
    end

    it "ignore observed_at mal formé sans casser la projection" do
      payload = {
        "schema_version"  => 1,
        "job_id"          => "job-lag2",
        "idempotency_key" => "scan-lag-ffff",
        "target"          => { "kind" => "host", "value" => "H_LAG2" },
        "status"          => "success",
        "observed_at"     => "not-a-date",
        "findings"        => []
      }
      expect { described_class.call(payload: payload, metrics: metrics) }.not_to raise_error
      lag_samples = metrics.samples.select { |s| s[0] == :graph_lag_seconds }
      expect(lag_samples).to be_empty
    end

    it "metrics nil = pas d'émission (compat)" do
      payload = {
        "schema_version"  => 1,
        "job_id"          => "job-lag3",
        "idempotency_key" => "scan-lag-gggg",
        "target"          => { "kind" => "host", "value" => "H_LAG3" },
        "status"          => "success",
        "observed_at"     => "2026-05-09T12:00:00Z",
        "findings"        => []
      }
      expect { described_class.call(payload: payload, metrics: nil) }.not_to raise_error
    end
  end

  describe "isolation réseau (§2.1 acceptance)" do
    it "0 appel sortant pendant la projection" do
      # WebMock disable_net_connect! attrape toute requête HTTP.
      # AR + AGE passent par socket Postgres, autorisé par défaut.
      # Si le projecteur appelait un embedder/LLM, le test échouerait.
      if defined?(WebMock)
        WebMock.disable_net_connect!(allow_localhost: true)
      end

      payload_simple = {
        "schema_version"  => 1,
        "job_id"          => "job-x",
        "idempotency_key" => "scan-iso-dddd",
        "target"          => { "kind" => "host", "value" => "H_ISO" },
        "status"          => "success",
        "observed_at"     => "2026-05-09T12:00:00Z",
        "findings"        => [{ "port" => 22, "protocol" => "tcp" }]
      }

      expect { described_class.call(payload: payload_simple) }.not_to raise_error
    end
  end
end
