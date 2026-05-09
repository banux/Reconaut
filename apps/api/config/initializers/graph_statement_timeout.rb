# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Timeout d'execution des templates Cypher.
#
# Source : openspec/changes/add-graph-retrieval/tasks.md section 4.5.
# Defaut 1500 ms ; configurable via RECONAUT_GRAPH_TEMPLATE_TIMEOUT_MS.
#
# Le timeout cote Ruby (Timeout.timeout) est doube par un timeout cote
# Postgres pour les sessions du role reconaut_graph_reader. C'est ici
# que le pool de connexions graphe se voit poser SET statement_timeout.

Rails.application.config.after_initialize do
  next if ENV["RECONAUT_SKIP_GRAPH_INITIALIZER"] == "1"
  next unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

  begin
    ms = Integer(ENV.fetch("RECONAUT_GRAPH_TEMPLATE_TIMEOUT_MS", "1500"))
    ActiveRecord::Base.connection.execute("SET statement_timeout = '#{ms}ms'")
  rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
    # Boot sans DB (par ex. assets:precompile en CI) : silent skip.
  end
end
