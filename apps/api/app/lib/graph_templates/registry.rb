# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Registre des templates Cypher parametres consommes par l'agent.
#
# Source de verite :
#   openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md
#     Requirement: Parameterized Read-Only Query Templates
#   openspec/changes/add-graph-retrieval/tasks.md sections 3.1, 3.3, 3.4
#
# Contrat :
#   - Chaque template a un template_id stable, une signature de parametres
#     typee (params: { name => spec }) et un cypher fixe (string).
#     Le LLM choisit un template_id et fournit les parametres ; il ne genere
#     JAMAIS de Cypher.
#   - Les templates sont en lecture seule : Linter rejette toute clause
#     mutante (CREATE / MERGE / SET / DELETE / DETACH / REMOVE).
#   - Les parametres typiques (depth, limit) sont valides : depth in [1,3],
#     limit in [1,100].
module GraphTemplates
  class Error < StandardError; end
  class TemplateNotReadOnlyError < Error; end
  class UnknownTemplateError < Error; end
  class ParamOutOfRangeError < Error; end
  class ParamTypeError < Error; end
  class MissingParamError < Error; end

  # Clauses Cypher mutantes interdites dans tout template enregistre.
  # On match sur des frontieres de mots, insensible a la casse, en sautant
  # les litteraux de chaine pour eviter les faux positifs sur du contenu
  # textuel comme un message d'erreur.
  FORBIDDEN_CLAUSES = %w[CREATE MERGE SET DELETE DETACH REMOVE].freeze

  # Plages autorisees pour les parametres normalises a noms reserves.
  PARAM_RANGES = {
    depth: (1..3),
    limit: (1..100)
  }.freeze

  Template = Struct.new(:id, :params, :cypher, keyword_init: true) do
    def required_params
      params.select { |_, spec| spec[:required] != false }.keys
    end
  end

  module Registry
    @templates = {}

    module_function

    def reset!
      @templates = {}
    end

    def register(id:, params:, cypher:)
      assert_read_only!(id, cypher)
      @templates[id.to_s] = Template.new(
        id: id.to_s,
        params: params.transform_keys(&:to_sym),
        cypher: cypher
      ).freeze
    end

    def fetch(id)
      @templates.fetch(id.to_s) { raise UnknownTemplateError, "unknown template: #{id.inspect}" }
    end

    def ids
      @templates.keys
    end

    def all
      @templates.values
    end

    # Resoud un appel { template_id, params } : lookup + validation. Retourne
    # le Template + le hash de parametres normalises (cles symbol, valeurs
    # coercitees au type declare). Leve UnknownTemplateError /
    # MissingParamError / ParamTypeError / ParamOutOfRangeError.
    def resolve(template_id, raw_params)
      template = fetch(template_id)
      coerced = {}
      raw_params = raw_params.transform_keys(&:to_sym)

      template.params.each do |name, spec|
        if !raw_params.key?(name)
          if spec[:required] == false
            coerced[name] = spec[:default]
            next
          end
          raise MissingParamError, "missing required param: #{name}"
        end

        coerced[name] = coerce_and_check(name, raw_params.fetch(name), spec)
      end

      [template, coerced]
    end

    # --- Linter : rejette tout template qui contiendrait une clause mutante.
    def assert_read_only!(id, cypher)
      stripped = strip_string_literals(cypher)
      FORBIDDEN_CLAUSES.each do |clause|
        next unless stripped.match?(/(?<![A-Z_])#{clause}(?![A-Z_])/i)

        raise TemplateNotReadOnlyError,
              "template-not-readonly: forbidden clause #{clause} in #{id}"
      end
    end

    # Retire les chaines literales (entre apostrophes ou guillemets) avant le
    # match anti-clauses pour eviter de bloquer un template qui mentionne le
    # mot dans une chaine.
    def strip_string_literals(cypher)
      cypher.gsub(/'(?:\\.|[^'\\])*'/, "''").gsub(/"(?:\\.|[^"\\])*"/, '""')
    end

    # --- Validateur de parametres ---
    def coerce_and_check(name, value, spec)
      case spec.fetch(:type)
      when :integer
        coerced = Integer(value)
        if (range = PARAM_RANGES[name])
          unless range.cover?(coerced)
            raise ParamOutOfRangeError,
                  "param-out-of-range: #{name}=#{coerced}, expected in #{range}"
          end
        end
        if (min = spec[:min])
          raise ParamOutOfRangeError, "param-out-of-range: #{name}=#{coerced} < #{min}" if coerced < min
        end
        if (max = spec[:max])
          raise ParamOutOfRangeError, "param-out-of-range: #{name}=#{coerced} > #{max}" if coerced > max
        end
        coerced
      when :string
        unless value.is_a?(String)
          raise ParamTypeError, "param #{name} must be a string"
        end
        if (min = spec[:min_length]) && value.length < min
          raise ParamOutOfRangeError, "param #{name} shorter than #{min}"
        end
        if (max = spec[:max_length]) && value.length > max
          raise ParamOutOfRangeError, "param #{name} longer than #{max}"
        end
        value
      when :enum
        allowed = spec.fetch(:values)
        unless allowed.include?(value)
          raise ParamOutOfRangeError, "param #{name}=#{value.inspect} not in #{allowed.inspect}"
        end
        value
      else
        raise ParamTypeError, "unknown param type: #{spec[:type].inspect}"
      end
    rescue ArgumentError, TypeError => e
      raise ParamTypeError, "param #{name} type error: #{e.message}"
    end
  end
end
