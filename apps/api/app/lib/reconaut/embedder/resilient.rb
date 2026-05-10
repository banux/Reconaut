# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "timeout"

# Décorateur appliqué aux embedders réseau (Ollama, Mistral,
# OpenAICompatible) — PAS à Local (in-process, déjà rapide).
#
# Apporte :
#   - timeout strict par appel (défaut 2.5 s, env RECONAUT_EMBEDDER_TIMEOUT_S)
#   - circuit breaker maison (défaut 5 échecs / 30 s ouvre 60 s)
#   - compteurs in-memory exposés via #stats pour reconaut:doctor
#
# Substituable à l'embedder original (interface identique : embed,
# dim, provider). Les erreurs propagées sont :
#   - TimeoutError       : le backend a dépassé timeout_s
#   - CircuitOpenError   : le circuit est ouvert (refus immédiat)
#   - UnavailableError   : le backend a renvoyé une erreur (5xx, …)
#
# Cf. openspec/changes/add-embedder-pluggable/specs/agent-interface/spec.md
#   -> Requirement: Embedder Resilience
module Reconaut
  module Embedder
    class Resilient
      attr_reader :inner, :timeout_s

      def initialize(inner, timeout_s:, breaker_failures:, breaker_window_s:, breaker_open_s:)
        @inner       = inner
        @timeout_s   = timeout_s
        @breaker     = Breaker.new(
          failures: breaker_failures,
          window_s: breaker_window_s,
          open_s:   breaker_open_s
        )
        @failures_total = 0
        @last_error     = nil
      end

      def embed(texts:)
        if @breaker.open?
          @last_error = "circuit-open"
          raise CircuitOpenError, "embedder-circuit-open: provider=#{provider}"
        end

        result = nil
        begin
          Timeout.timeout(@timeout_s) do
            result = @inner.embed(texts: texts)
          end
        rescue Timeout::Error
          record_failure!("timeout")
          raise TimeoutError, "embedder-timeout: provider=#{provider} after #{@timeout_s}s"
        rescue UnavailableError => e
          record_failure!(e.message[0, 80])
          raise
        end

        @breaker.record_success!
        result
      end

      def dim      = @inner.dim
      def provider = @inner.provider

      # stats expose un Hash digérable par reconaut:doctor :
      #   { provider:, dim:, circuit_state:, failures_total:, last_error: }
      def stats
        {
          provider:       provider,
          dim:            dim,
          circuit_state:  @breaker.state,
          failures_total: @failures_total,
          last_error:     @last_error
        }
      end

      private

      def record_failure!(reason)
        @failures_total += 1
        @last_error = reason
        @breaker.record_failure!
      end
    end
  end
end
