# frozen_string_literal: true

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

  registry  = Reconaut::Registry.default
  retriever = registry.hybrid_retriever || nil_retriever

  # Si aucun retriever n'a été câblé (par ex. Postgres pas dispo),
  # on enregistre quand même les outils qui ne dépendent pas du
  # retrieval pour préserver doctor / heartbeats.
  next unless retriever

  Mcp::CoreTools.register_all!(
    retriever:          retriever,
    scope_storage:      registry.scope_storage,
    scan_enqueuer:      registry.scan_enqueuer,
    api_key_storage:    registry.api_key_store,
    ingestion_recorder: nil, # à câbler quand le ScanResultIngestor sera livré
    heartbeat_store:    registry.heartbeat_store
  )

  Rails.logger.info "[mcp] tools registered: #{Mcp::ToolRegistry.names.join(", ")}"
end

# Helper local : si le HybridRetriever n'est pas câblé en prod, on
# log un avertissement plutôt qu'un crash. Les tests qui exigent un
# retriever fonctionnel le câblent explicitement.
def nil_retriever
  warn "[mcp] no HybridRetriever wired in Registry — MCP tools depending on retrieval will be skipped"
  nil
end
