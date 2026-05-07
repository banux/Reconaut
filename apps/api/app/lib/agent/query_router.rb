# frozen_string_literal: true

require "json"
require_relative "../graph_templates/registry"

# Routeur de requete agent : decompose une requete utilisateur en
# (a) une partie semantique pour le rappel vectoriel, (b) une liste de
# template_ids et leurs parametres pour l'expansion graphe.
#
# Source de verite :
#   openspec/changes/add-graph-retrieval/specs/agent-interface/spec.md
#     -> Requete structurelle declenche le chemin graphe
#   openspec/changes/add-graph-retrieval/tasks.md section 4.1
#
# Le LLM ne voit JAMAIS de Cypher. Il voit la liste des template_ids
# disponibles avec leur signature de parametres, et il rend un JSON
# strictement structure :
#   { "templates": [{template_id, params}], "semantic_query": "..." }
#
# Le client LLM est injecte ; n'importe quel objet repondant a
# `complete(prompt:)` -> String fonctionne (Mistral, Ollama, modele
# local, mock dans les tests).
module Agent
  class QueryRouter
    class InvalidLLMResponseError < StandardError; end

    Decision = Struct.new(:templates, :semantic_query, keyword_init: true) do
      def graph_path?
        templates.any?
      end

      def vector_path?
        !semantic_query.to_s.strip.empty?
      end
    end

    Plan = Struct.new(:template_id, :params, keyword_init: true)

    PROMPT_HEADER = <<~TEXT.freeze
      Tu es un routeur de requete pour un outil de cartographie d'actifs.
      Reponds UNIQUEMENT par un objet JSON valide de la forme :
        { "templates": [ { "template_id": "...", "params": { ... } } ], "semantic_query": "..." }
      Ne genere JAMAIS de Cypher, de SQL, ni d'explication libre.
      Choisis 0, 1 ou plusieurs templates parmi le catalogue ci-dessous.
      Si aucun template ne s'applique, renvoie templates: [] et place les
      mots-cles dans semantic_query.
    TEXT

    def initialize(llm_client:, registry: GraphTemplates::Registry)
      @llm_client = llm_client
      @registry   = registry
    end

    # Construit le prompt envoye au LLM en listant les templates
    # disponibles. Public pour permettre un audit facile (tests +
    # journalisation).
    def build_prompt(user_query)
      tools = @registry.all.map do |template|
        {
          template_id: template.id,
          params: template.params.transform_values { |spec| spec.slice(:type, :values) }
        }
      end

      <<~TEXT
        #{PROMPT_HEADER}
        Catalogue : #{JSON.generate(tools)}
        Requete utilisateur : #{user_query.inspect}
      TEXT
    end

    # Appelle le LLM et parse sa reponse. Resoud chaque template choisi
    # via `GraphTemplates::Registry.resolve` -> les parametres invalides
    # sont rejetes en levant l'exception correspondante.
    #
    # Sur reponse LLM mal formee (JSON invalide, structure inconnue), on
    # leve InvalidLLMResponseError et l'appelant tombera en chemin
    # vectoriel pur (cf. exigence "ensemble de resultats vide est explicite"
    # de agent-interface).
    def route(user_query)
      raw = @llm_client.complete(prompt: build_prompt(user_query))
      parsed = parse_response!(raw)

      templates = Array(parsed["templates"]).map do |entry|
        template_id = entry.fetch("template_id") { raise InvalidLLMResponseError, "template_id missing" }
        params      = entry.fetch("params", {})
        # `resolve` valide les parametres et leve si invalides ; on laisse
        # l'exception remonter pour que le pipeline trace l'erreur en audit.
        @registry.resolve(template_id, params)
        Plan.new(template_id: template_id, params: params.transform_keys(&:to_sym))
      end

      Decision.new(
        templates: templates,
        semantic_query: parsed["semantic_query"].to_s
      )
    end

    private

    def parse_response!(raw)
      JSON.parse(raw)
    rescue JSON::ParserError => e
      raise InvalidLLMResponseError, "LLM returned non-JSON: #{e.message}"
    end
  end
end
