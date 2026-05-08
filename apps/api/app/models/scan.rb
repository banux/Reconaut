# frozen_string_literal: true

# Scan : matérialisation persistante d'un job de scan. Sert aux outils
# MCP `list_scans` / `get_scan_status` (cf. mcp-as-primary-entrypoint
# §1.1) au-dessus de la file good_jobs vivante.
class Scan < ApplicationRecord
  STATUSES = %w[queued running done failed].freeze

  validates :scan_kind, presence: true
  validates :target_kind, presence: true
  validates :target_value, presence: true, length: { maximum: 255 }
  validates :idempotency_key, presence: true, uniqueness: true, length: { maximum: 128 }
  validates :status, inclusion: { in: STATUSES }

  scope :recent, ->(limit = 50) { order(enqueued_at: :desc).limit(limit) }
end
