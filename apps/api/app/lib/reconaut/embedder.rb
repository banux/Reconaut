# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Interface Embedder + selection par variable d'environnement.
#
# Source de verite :
#   openspec/project.md (section Stack -> Embeddings pluggables)
#   openspec/changes/init-reconaut-platform/tasks.md sections 4.1 / 4.2
#
# Quatre implementations livrees, choix par RECONAUT_EMBEDDER_PROVIDER :
#   - local    (defaut, zero appel sortant)
#   - ollama   (sidecar HTTP local, RECONAUT_EMBEDDER_OLLAMA_URL + MODEL)
#   - mistral  (API EU, RECONAUT_EMBEDDER_MISTRAL_API_KEY)
#   - openai-compatible (endpoint generique, BASE_URL + API_KEY + MODEL)
#
# Contrat commun : `embed(texts:) -> Array<Array<Float>>`. Les 4
# implementations partagent la meme signature pour rester
# substituables.
module Reconaut
  module Embedder
    class MisconfiguredError < StandardError; end
    class UnavailableError < StandardError; end
    # Le wrapper de résilience (cf. Reconaut::Embedder::Resilient) lève
    # ces erreurs typées pour distinguer (a) un timeout de l'appel,
    # (b) un circuit breaker ouvert, (c) un backend cassé. Sémantiques
    # différentes : une 503 mappée par Agent::ChatController peut
    # remonter `reason` plus précis.
    class TimeoutError    < StandardError; end
    class CircuitOpenError < StandardError; end

    # --- Interface implicite : toute classe qui a `embed(texts:)` est
    # acceptable. On documente le contrat ici a defaut de Sorbet.
    # `texts:` Array<String>, retourne Array<Array<Float>> de meme taille.
    # `dim` retourne la dimension du vecteur emis (entier > 0).

    # --- Selection par env ---------------------------------------------
    PROVIDERS = %w[local ollama mistral openai-compatible].freeze

    DEFAULT_LOCAL_DIM = 384

    module_function

    # Construit l'instance pour une config donnee. Soulagement par env
    # par defaut, mais on peut passer un hash explicite (utile en tests).
    #
    # Les providers réseau (`ollama`, `mistral`, `openai-compatible`)
    # sont enveloppés automatiquement dans `Resilient` (timeout +
    # circuit breaker). `local` reste exempt — in-process, pas de
    # réseau, aucun bénéfice à wrapper.
    def build(env: ENV)
      provider = env.fetch("RECONAUT_EMBEDDER_PROVIDER", "local").to_s.downcase
      unless PROVIDERS.include?(provider)
        raise MisconfiguredError,
              "embedder-misconfigured: unknown provider #{provider.inspect}, must be one of #{PROVIDERS.join(",")}"
      end

      raw = case provider
            when "local"
              Local.new(dim: Integer(env.fetch("RECONAUT_EMBEDDER_LOCAL_DIM", DEFAULT_LOCAL_DIM)))
            when "ollama"
              url   = env["RECONAUT_EMBEDDER_OLLAMA_URL"]
              model = env["RECONAUT_EMBEDDER_OLLAMA_MODEL"]
              require_env!(provider, url: url, model: model)
              Ollama.new(url: url, model: model)
            when "mistral"
              api_key = env["RECONAUT_EMBEDDER_MISTRAL_API_KEY"]
              model   = env.fetch("RECONAUT_EMBEDDER_MISTRAL_MODEL", "mistral-embed")
              require_env!(provider, api_key: api_key)
              Mistral.new(api_key: api_key, model: model)
            when "openai-compatible"
              base_url = env["RECONAUT_EMBEDDER_OPENAI_BASE_URL"]
              api_key  = env["RECONAUT_EMBEDDER_OPENAI_API_KEY"]
              model    = env["RECONAUT_EMBEDDER_OPENAI_MODEL"]
              require_env!(provider, base_url: base_url, api_key: api_key, model: model)
              OpenAICompatible.new(base_url: base_url, api_key: api_key, model: model)
            end

      provider == "local" ? raw : wrap_resilient(raw, env)
    end

    def wrap_resilient(inner, env)
      Resilient.new(
        inner,
        timeout_s:        Float(env.fetch("RECONAUT_EMBEDDER_TIMEOUT_S", 2.5)),
        breaker_failures: Integer(env.fetch("RECONAUT_EMBEDDER_BREAKER_FAILURES", 5)),
        breaker_window_s: Integer(env.fetch("RECONAUT_EMBEDDER_BREAKER_WINDOW_S", 30)),
        breaker_open_s:   Integer(env.fetch("RECONAUT_EMBEDDER_BREAKER_OPEN_S", 60))
      )
    end

    def require_env!(provider, **fields)
      missing = fields.select { |_, v| v.nil? || v.to_s.strip.empty? }.keys
      return if missing.empty?

      raise MisconfiguredError,
            "embedder-misconfigured: provider=#{provider} missing #{missing.join(", ")}"
    end
  end
end

require_relative "embedder/local"
require_relative "embedder/ollama"
require_relative "embedder/mistral"
require_relative "embedder/openai_compatible"
require_relative "embedder/breaker"
require_relative "embedder/resilient"
