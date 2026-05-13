# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# LeaseReleaseJob : re-queue les jobs dont le lease (claim_scan_job) est
# expiré. Tourne périodiquement (cron 1 minute) — quand un worker crashe
# entre claim et submit/fail, son job reste avec `performed_at != NULL`
# et `finished_at == NULL` ; ce job le remet `performed_at = NULL` pour
# qu'un autre worker puisse le re-claim.
#
# Source de vérité :
#   openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
#     -> Requirement: Recurring job de "lease release"
class LeaseReleaseJob < ApplicationJob
  queue_as :maintenance

  # Aligné sur le lease par défaut de Scanner::ClaimJob (DEFAULT_LEASE_SECONDS=300).
  LEASE_TIMEOUT_SECONDS = 300

  def perform
    return unless ActiveRecord::Base.connection.table_exists?(:good_jobs)

    cutoff = Time.now.utc - LEASE_TIMEOUT_SECONDS
    ActiveRecord::Base.connection.exec_query(
      "UPDATE good_jobs SET performed_at = NULL WHERE finished_at IS NULL AND performed_at IS NOT NULL AND performed_at < $1",
      "LeaseReleaseJob",
      [cutoff]
    )
  end
end
