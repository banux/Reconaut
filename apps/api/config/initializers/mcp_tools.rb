# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Enregistrement des outils MCP au boot du process Rails. Sans cet
# initializer, le ToolRegistry est vide en production et les routes
# /mcp/tools/* renvoient unknown_tool sur tout. Les tests qui veulent
# customiser leur set d'outils continuent d'appeler
# Mcp::CoreTools.register_all! eux-mêmes après reset.
#
# Sources de vérité :
#   openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
#     -> Requirement: MCP Tool Surface
#   openspec/changes/add-tech-stack/tasks.md section 6 (acceptance
#     bin/doctor : last_worker_heartbeat consomme le tool MCP
#     submit_heartbeat).

Rails.application.config.after_initialize do
  next if Rails.env.test? # les specs RSpec gèrent leur propre setup
  next unless defined?(Mcp::CoreTools) && defined?(Reconaut::Registry)

  registry = Reconaut::Registry.default

  # Si aucun HybridRetriever n'est câblé (cas par défaut en dev :
  # pipeline d'embedding pas encore branché), on passe un stub qui
  # retourne une Response vide. Les tools qui dépendent du retrieval
  # (`agent_chat`, `search_hosts`, `get_host`) sont quand même
  # enregistrés et répondent `{rows: [], warnings: ["…"]}` plutôt que
  # 404 unknown_tool. Mieux que de masquer toute la surface MCP.
  retriever = registry.hybrid_retriever || StubRetriever.new

  Mcp::CoreTools.register_all!(
    retriever:          retriever,
    scope_storage:      registry.scope_storage,
    scan_enqueuer:      registry.scan_enqueuer,
    api_key_storage:    registry.api_key_store,
    ingestion_recorder: nil, # à câbler quand le ScanResultIngestor sera livré
    heartbeat_store:    registry.heartbeat_store,
    scan_store:         registry.scan_store
  )

  if registry.hybrid_retriever.nil?
    Rails.logger.warn "[mcp] HybridRetriever not wired — retrieval tools return empty results (#{Mcp::ToolRegistry.names.size} tools registered)"
  else
    Rails.logger.info "[mcp] tools registered: #{Mcp::ToolRegistry.names.join(", ")}"
  end
end

# StubRetriever : retourne une Response vide quand aucun pipeline
# d'embedding n'est câblé. Conserve l'enregistrement de l'outil
# `agent_chat` / `search_hosts` (le client reçoit un 200 + rows=[],
# warnings=[...] au lieu d'un 404 unknown_tool qui empêche toute
# inspection de la surface MCP).
#
# Le pipeline réel est câblé par un futur change (cf.
# `add-embedding-pipeline`) qui pose `Registry.default.hybrid_retriever`.
class StubRetriever
  def call(_query)
    require "agent/hybrid_retriever" unless defined?(::Agent::HybridRetriever)

    ::Agent::HybridRetriever::Response.new(
      rows:           [],
      citations:      [],
      warnings:       ["retriever-not-wired"],
      retrieval_path: "none",
      duration_ms:    0
    )
  end
end
