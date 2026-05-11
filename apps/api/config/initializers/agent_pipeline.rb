# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Câble `Reconaut::Registry.default.hybrid_retriever` au boot Rails
# avec un HybridRetriever vectoriel réel (cf. add-embedding-pipeline).
#
# Cf. openspec/changes/add-embedding-pipeline/specs/agent-interface/spec.md
#   -> Requirement: Pipeline Wired into Registry at Boot
#
# Si Postgres / extension vector / table embeddings ne sont pas
# disponibles, log un warning et laisse hybrid_retriever à nil. Le
# StubRetriever câblé par mcp_tools.rb prend alors le relais —
# comportement gracieux (cf. commit 94afc76).
#
# NB : ce fichier est nommé `agent_pipeline.rb` pour qu'il soit chargé
# AVANT `mcp_tools.rb` dans l'ordre alphabétique (Rails charge les
# initializers de `config/initializers/` triés par nom). Le retriever
# posé ici est consommé par `mcp_tools.rb` (CoreTools.register_all!).

Rails.application.config.after_initialize do
  next if Rails.env.test? # les specs câblent leur propre retriever
  next unless defined?(::Reconaut::Agent::Pipeline) && defined?(::Embedding)

  if ::Embedding.table_exists?
    registry = ::Reconaut::Registry.default
    registry.hybrid_retriever = ::Reconaut::Agent::Pipeline.build(registry: registry)
    provider = registry.embedder.respond_to?(:provider) ? registry.embedder.provider : "?"
    dim      = registry.embedder.respond_to?(:dim) ? registry.embedder.dim : "?"
    Rails.logger.info "[agent] pipeline wired (provider=#{provider} dim=#{dim})"
  else
    Rails.logger.warn "[agent] pipeline not wired (table embeddings absente — exec rails db:migrate)"
  end
rescue StandardError => e
  Rails.logger.warn "[agent] pipeline not wired : #{e.class}: #{e.message}"
end
