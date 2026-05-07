# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/graph_templates/registry"

RSpec.describe GraphTemplates::Registry do
  before { described_class.reset! }

  describe ".register" do
    it "accepte un template lecture-seule" do
      described_class.register(
        id: "cert_cluster",
        params: { cert_sha256: { type: :string, min_length: 64, max_length: 64 } },
        cypher: "MATCH (c:Certificate {sha256: $cert_sha256})<-[:PRESENTS]-(h:Host) RETURN h"
      )
      expect(described_class.ids).to include("cert_cluster")
    end

    it "rejette un template avec DETACH DELETE" do
      expect {
        described_class.register(
          id: "evil_delete",
          params: {},
          cypher: "MATCH (n) DETACH DELETE n"
        )
      }.to raise_error(
        GraphTemplates::TemplateNotReadOnlyError,
        /template-not-readonly: forbidden clause (DETACH|DELETE)/
      )
    end

    it "rejette un template avec CREATE" do
      expect {
        described_class.register(
          id: "evil_create",
          params: {},
          cypher: "CREATE (n:Host {id: 'x'}) RETURN n"
        )
      }.to raise_error(GraphTemplates::TemplateNotReadOnlyError, /CREATE/)
    end

    it "rejette MERGE / SET / REMOVE" do
      %w[MERGE SET REMOVE].each do |clause|
        expect {
          described_class.register(
            id: "evil_#{clause.downcase}",
            params: {},
            cypher: "MATCH (n) #{clause} n.flag = true RETURN n"
          )
        }.to raise_error(GraphTemplates::TemplateNotReadOnlyError, /#{clause}/)
      end
    end

    it "ne se laisse pas leurrer par un mot interdit dans une chaine literale" do
      expect {
        described_class.register(
          id: "host_with_literal",
          params: {},
          cypher: "MATCH (h:Host {note: 'CREATE was here once'}) RETURN h"
        )
      }.not_to raise_error
    end

    it "ne confond pas une lettre majuscule au milieu d'un identifiant" do
      # Un identifiant comme `RECREATE_INDEX` ne doit pas etre detecte comme CREATE.
      expect {
        described_class.register(
          id: "non_keyword",
          params: {},
          cypher: "MATCH (n {label: 'RECREATE_INDEX'}) RETURN n"
        )
      }.not_to raise_error
    end
  end

  describe ".fetch" do
    it "leve UnknownTemplateError sur un id absent" do
      expect { described_class.fetch("nope") }
        .to raise_error(GraphTemplates::UnknownTemplateError)
    end
  end

  describe ".resolve" do
    before do
      described_class.register(
        id: "host_neighborhood",
        params: {
          host_id: { type: :string, min_length: 1, max_length: 64 },
          depth:   { type: :integer }
        },
        cypher: "MATCH (h:Host {id: $host_id})-[*1..3]-(n) RETURN n LIMIT 100"
      )
    end

    it "coerce les parametres et retourne le template" do
      template, params = described_class.resolve(
        "host_neighborhood",
        { "host_id" => "abc", "depth" => "2" }
      )
      expect(template.id).to eq("host_neighborhood")
      expect(params).to eq(host_id: "abc", depth: 2)
    end

    it "rejette depth > 3" do
      expect {
        described_class.resolve("host_neighborhood", host_id: "abc", depth: 10)
      }.to raise_error(GraphTemplates::ParamOutOfRangeError, /depth=10/)
    end

    it "rejette depth < 1" do
      expect {
        described_class.resolve("host_neighborhood", host_id: "abc", depth: 0)
      }.to raise_error(GraphTemplates::ParamOutOfRangeError, /depth=0/)
    end

    it "exige les parametres requis" do
      expect {
        described_class.resolve("host_neighborhood", depth: 2)
      }.to raise_error(GraphTemplates::MissingParamError, /host_id/)
    end

    it "rejette les valeurs non-coercitibles" do
      expect {
        described_class.resolve("host_neighborhood", host_id: "abc", depth: "two")
      }.to raise_error(GraphTemplates::ParamTypeError)
    end
  end

  describe "limit param range" do
    before do
      described_class.register(
        id: "assets_by_kind",
        params: {
          kind:  { type: :enum, values: %w[Host Service Domain] },
          limit: { type: :integer, required: false, default: 50 }
        },
        cypher: "MATCH (n) WHERE labels(n)[0] = $kind RETURN n LIMIT $limit"
      )
    end

    it "applique le default sur un parametre optionnel manquant" do
      _t, params = described_class.resolve("assets_by_kind", kind: "Host")
      expect(params[:limit]).to eq(50)
    end

    it "rejette limit > 100" do
      expect {
        described_class.resolve("assets_by_kind", kind: "Host", limit: 1000)
      }.to raise_error(GraphTemplates::ParamOutOfRangeError, /limit=1000/)
    end

    it "rejette une enum invalide" do
      expect {
        described_class.resolve("assets_by_kind", kind: "Banana")
      }.to raise_error(GraphTemplates::ParamOutOfRangeError, /kind/)
    end
  end
end
