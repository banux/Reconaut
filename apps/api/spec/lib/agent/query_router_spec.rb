# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../../../app/lib/agent/query_router"
require_relative "../../../app/lib/graph_templates/core_set"

RSpec.describe Agent::QueryRouter do
  before { GraphTemplates::CoreSet.register_all! }

  # Fake LLM client : controllable depuis le test, repond ce qu'on lui dit.
  class FakeLLM
    def initialize(response)
      @response = response
      @captured_prompts = []
    end

    attr_reader :captured_prompts

    def complete(prompt:)
      @captured_prompts << prompt
      @response
    end
  end

  describe "#build_prompt" do
    it "liste les 10 templates noyau et leurs parametres" do
      router = described_class.new(llm_client: FakeLLM.new("{}"))
      prompt = router.build_prompt("hotes en France")

      expect(prompt).to include("cert_cluster")
      expect(prompt).to include("host_neighborhood")
      expect(prompt).to include("subsidiaries_assets")
      expect(prompt).to include('"hotes en France"')
    end

    it "instruit explicitement le LLM de ne pas generer de Cypher" do
      router = described_class.new(llm_client: FakeLLM.new("{}"))
      prompt = router.build_prompt("anything")

      expect(prompt).to match(/JAMAIS de Cypher/)
    end
  end

  describe "#route" do
    it "decompose une requete structurelle en {templates, semantic_query}" do
      llm_response = JSON.generate(
        templates: [
          { template_id: "cert_cluster", params: { cert_sha256: "a" * 64 } }
        ],
        semantic_query: "cert"
      )
      router = described_class.new(llm_client: FakeLLM.new(llm_response))

      decision = router.route("hotes partageant ce cert")
      expect(decision.graph_path?).to be true
      expect(decision.templates.first.template_id).to eq("cert_cluster")
      expect(decision.semantic_query).to eq("cert")
    end

    it "tombe en chemin vectoriel pur si templates est vide" do
      llm_response = JSON.generate(templates: [], semantic_query: "nginx 1.18")
      router = described_class.new(llm_client: FakeLLM.new(llm_response))

      decision = router.route("nginx vulnerables")
      expect(decision.graph_path?).to be false
      expect(decision.vector_path?).to be true
    end

    it "rejette une reponse JSON malformee" do
      router = described_class.new(llm_client: FakeLLM.new("not json"))

      expect { router.route("anything") }
        .to raise_error(Agent::QueryRouter::InvalidLLMResponseError, /non-JSON/)
    end

    it "rejette un template_id inconnu (forwarde l'erreur du registry)" do
      llm_response = JSON.generate(
        templates: [{ template_id: "evil_template", params: {} }],
        semantic_query: ""
      )
      router = described_class.new(llm_client: FakeLLM.new(llm_response))

      expect { router.route("anything") }
        .to raise_error(GraphTemplates::UnknownTemplateError)
    end

    it "rejette des parametres invalides (forwarde la validation)" do
      llm_response = JSON.generate(
        templates: [
          { template_id: "host_neighborhood", params: { host_id: "h", depth: 99 } }
        ],
        semantic_query: ""
      )
      router = described_class.new(llm_client: FakeLLM.new(llm_response))

      expect { router.route("voisinage de h") }
        .to raise_error(GraphTemplates::ParamOutOfRangeError, /depth=99/)
    end

    it "supporte plusieurs templates dans une meme decision" do
      llm_response = JSON.generate(
        templates: [
          { template_id: "as_hosts", params: { as_number: 16276 } },
          { template_id: "domain_chain", params: { domain: "example.fr" } }
        ],
        semantic_query: "ovh"
      )
      router = described_class.new(llm_client: FakeLLM.new(llm_response))

      decision = router.route("hotes ovh sur example.fr")
      expect(decision.templates.length).to eq(2)
      expect(decision.templates.map(&:template_id))
        .to contain_exactly("as_hosts", "domain_chain")
    end
  end
end
