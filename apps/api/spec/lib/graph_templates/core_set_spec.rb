# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/lib/graph_templates/core_set"

RSpec.describe GraphTemplates::CoreSet do
  before { GraphTemplates::Registry.reset! }

  describe ".register_all!" do
    it "enregistre les 10 templates noyau de la spec 3.2" do
      described_class.register_all!
      expect(GraphTemplates::Registry.ids).to contain_exactly(
        "cert_cluster",
        "host_neighborhood",
        "assets_by_kind",
        "service_with_vulnerability",
        "as_hosts",
        "domain_chain",
        "path_between",
        "host_certificates",
        "cve_exposed_count",
        "subsidiaries_assets"
      )
    end

    it "tous les templates ont un cypher non-vide et passent le linter read-only" do
      described_class.register_all!
      GraphTemplates::Registry.all.each do |t|
        expect(t.cypher).not_to be_empty, "template #{t.id} a un Cypher vide"
        # assert_read_only! aurait deja leve si une clause mutante etait presente.
        expect { GraphTemplates::Registry.assert_read_only!(t.id, t.cypher) }
          .not_to raise_error
      end
    end

    it "aucun template ne contient de filtre tenant_id (modele tenant unique)" do
      described_class.register_all!
      GraphTemplates::Registry.all.each do |t|
        expect(t.cypher).not_to match(/tenant_id/i),
                                "template #{t.id} contient une reference tenant_id"
        expect(t.params.keys).not_to include(:tenant_id, :tenant, :caller_tenant)
      end
    end

    it "depth est borne a [1,3] partout ou il apparait" do
      described_class.register_all!
      GraphTemplates::Registry.all.each do |t|
        next unless t.params.key?(:depth)
        # depth ne porte pas de min/max custom dans le spec donc PARAM_RANGES
        # s'applique : 1..3.
        expect {
          GraphTemplates::Registry.resolve(t.id, sample_params(t).merge(depth: 10))
        }.to raise_error(GraphTemplates::ParamOutOfRangeError)
      end
    end

    it "limit est borne a [1,100] partout ou il apparait comme integer" do
      described_class.register_all!
      GraphTemplates::Registry.all.each do |t|
        next unless t.params.key?(:limit)
        expect {
          GraphTemplates::Registry.resolve(t.id, sample_params(t).merge(limit: 1000))
        }.to raise_error(GraphTemplates::ParamOutOfRangeError)
      end
    end

    describe "validation par template (cas négatifs)" do
      before { described_class.register_all! }

      it "cert_cluster rejette un sha256 trop court" do
        expect {
          GraphTemplates::Registry.resolve("cert_cluster", cert_sha256: "abc")
        }.to raise_error(GraphTemplates::ParamOutOfRangeError)
      end

      it "service_with_vulnerability rejette un cve_id trop court" do
        expect {
          GraphTemplates::Registry.resolve("service_with_vulnerability", cve_id: "X")
        }.to raise_error(GraphTemplates::ParamOutOfRangeError)
      end

      it "as_hosts rejette un as_number non-entier" do
        expect {
          GraphTemplates::Registry.resolve("as_hosts", as_number: "OVH")
        }.to raise_error(GraphTemplates::ParamTypeError)
      end

      it "assets_by_kind rejette un kind hors enum" do
        expect {
          GraphTemplates::Registry.resolve("assets_by_kind", kind: "Banana")
        }.to raise_error(GraphTemplates::ParamOutOfRangeError)
      end

      it "host_neighborhood rejette depth=0" do
        expect {
          GraphTemplates::Registry.resolve("host_neighborhood", host_id: "h1", depth: 0)
        }.to raise_error(GraphTemplates::ParamOutOfRangeError)
      end

      it "host_neighborhood accepte depth=2" do
        _t, params = GraphTemplates::Registry.resolve(
          "host_neighborhood", host_id: "h1", depth: 2
        )
        expect(params[:depth]).to eq(2)
        expect(params[:host_id]).to eq("h1")
      end
    end
  end

  # Genere un hash de parametres minimal valide pour un template donne.
  # Sert aux tests parametriques qui veulent muter un seul champ.
  def sample_params(template)
    sample = {}
    template.params.each do |name, spec|
      next if spec[:required] == false

      sample[name] =
        case spec[:type]
        when :string  then ("a" * (spec[:min_length] || 1))
        when :integer then 1
        when :enum    then spec[:values].first
        end
    end
    # Cas particulier cert_sha256 : 64 chars exact pour passer min/max.
    sample[:cert_sha256] = "a" * 64 if template.params.key?(:cert_sha256)
    sample[:cve_id] = "CVE-2024-12345" if template.params.key?(:cve_id)
    sample
  end
end
