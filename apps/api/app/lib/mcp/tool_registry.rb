# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Registre des outils MCP exposes via /mcp/tools/*. Source de verite :
#   openspec/changes/init-reconaut-platform/specs/mcp-server/spec.md
#   openspec/changes/init-reconaut-platform/tasks.md sections 5.1 / 5.2 / 5.3
#
# Chaque outil porte :
#   - un `name` stable (snake_case)
#   - un `scopes` : Array<Symbol> de scopes RBAC requis
#   - un `params_schema` : Hash compatible avec GraphTemplates style
#     (typage simple : :string / :integer / :enum, required par defaut)
#   - un `handler` callable qui prend (params:, caller_id:) -> Hash
#
# La cle de design : separer la definition declarative (registre) de
# l'execution (controller). Les tests exercent les outils en isolation
# sans booter Rails.
module Mcp
  class Error < StandardError; end
  class UnknownToolError < Error; end
  class MissingParamError < Error; end
  class ParamTypeError < Error; end
  class ParamOutOfRangeError < Error; end
  class ScopeError < Error; end

  Tool = Struct.new(:name, :scopes, :params_schema, :handler, keyword_init: true) do
    def call(params:, caller_id: "anonymous", caller_scopes: [])
      missing_scopes = scopes - Array(caller_scopes)
      raise ScopeError, "missing scopes: #{missing_scopes.join(",")}" unless missing_scopes.empty?

      coerced = ToolRegistry.coerce_params(params_schema, params)
      handler.call(params: coerced, caller_id: caller_id)
    end
  end

  module ToolRegistry
    @tools = {}

    module_function

    def reset!
      @tools = {}
    end

    def register(name:, scopes:, params_schema:, &handler)
      raise ArgumentError, "handler required" unless handler

      @tools[name.to_s] = Tool.new(
        name:           name.to_s,
        scopes:         Array(scopes).map(&:to_sym),
        params_schema:  params_schema || {},
        handler:        handler
      ).freeze
    end

    def fetch(name)
      @tools.fetch(name.to_s) { raise UnknownToolError, "unknown tool: #{name.inspect}" }
    end

    def names = @tools.keys

    def all = @tools.values

    # Coerce + valide les parametres selon un mini-schema. Reuse partiel
    # de la logique GraphTemplates::Registry mais sans les plages
    # reservees (depth/limit) - les outils MCP peuvent declarer leurs
    # propres bornes via min/max.
    def coerce_params(schema, raw_params)
      raw_params = (raw_params || {}).transform_keys(&:to_sym)
      coerced = {}

      schema.each do |name, spec|
        if !raw_params.key?(name)
          if spec[:required] == false
            coerced[name] = spec[:default]
            next
          end
          raise MissingParamError, "missing required param: #{name}"
        end
        coerced[name] = coerce(name, raw_params.fetch(name), spec)
      end

      coerced
    end

    def coerce(name, value, spec)
      case spec[:type]
      when :integer
        v = Integer(value)
        if (min = spec[:min]) && v < min
          raise ParamOutOfRangeError, "#{name}=#{v} below min=#{min}"
        end
        if (max = spec[:max]) && v > max
          raise ParamOutOfRangeError, "#{name}=#{v} above max=#{max}"
        end
        v
      when :string
        raise ParamTypeError, "#{name} must be a string" unless value.is_a?(String)

        if (min = spec[:min_length]) && value.length < min
          raise ParamOutOfRangeError, "#{name} shorter than #{min}"
        end
        if (max = spec[:max_length]) && value.length > max
          raise ParamOutOfRangeError, "#{name} longer than #{max}"
        end
        value
      when :enum
        unless spec.fetch(:values).include?(value)
          raise ParamOutOfRangeError, "#{name} not in enum"
        end
        value
      when :hash
        # Hash arbitraire (pour les tools qui acceptent un payload
        # libre, validé séparément contre un JSON Schema). Utilisé par
        # ingest_scan_result qui valide ensuite contre ScanResultV1.
        unless value.is_a?(Hash)
          raise ParamTypeError, "#{name} must be a hash"
        end
        value
      else
        raise ParamTypeError, "unknown spec type for #{name}"
      end
    rescue ArgumentError, TypeError => e
      raise ParamTypeError, "#{name}: #{e.message}"
    end
  end
end
