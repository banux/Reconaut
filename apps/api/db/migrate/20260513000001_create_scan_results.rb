# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Table scan_results : cible des écritures des workers Go via
# results.SQLStore (cf. apps/scanner/internal/results/sql.go).
#
# Le worker insère via :
#   INSERT INTO scan_results (idempotency_key, scan_kind, target_kind,
#                              target_value, status, observed_at)
#   VALUES ($1, ...) ON CONFLICT (idempotency_key) DO NOTHING
#   RETURNING idempotency_key
#
# Source de vérité :
#   openspec/changes/add-scanner-pgx-driver/specs/platform/spec.md
#     -> Requirement: Migration scan_results table
#
# Décisions :
#   - PK = idempotency_key (déduplication forte côté DB).
#   - Pas d'hypertable Timescale en v1 (différé à add-scan-results-hypertable).
#   - Pas de FK vers hosts/services/scans : le worker Go écrit sans
#     connaître les modèles AR. Le lien sémantique est résolu côté
#     Rails / MCP plus tard.
class CreateScanResults < ActiveRecord::Migration[8.1]
  def change
    create_table :scan_results, id: false do |t|
      t.text     :idempotency_key, null: false, primary_key: true
      t.text     :scan_kind,       null: false
      t.text     :target_kind,     null: false
      t.text     :target_value,    null: false
      t.text     :status,          null: false
      t.datetime :observed_at,     null: false
      t.timestamps default: -> { "NOW()" }
    end
    add_index :scan_results, :scan_kind
    add_index :scan_results, [:target_kind, :target_value]
    add_index :scan_results, :observed_at
  end
end
