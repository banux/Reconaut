# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# AuditLog : journal append-only des actions opérateur côté serveur.
# Cf. openspec/changes/init-reconaut-platform/tasks.md §6.3 (reformulé
# par drop-gdpr-framing en cadrage opérationnel).
#
# Append-only enforcé au niveau Postgres par TRIGGER (cf. migration
# 20260509000001_create_audit_log) : tout UPDATE/DELETE lève
# `PG::InsufficientPrivilege`. Le modèle Rails ne pose donc pas de
# garde supplémentaire — la base est la source de vérité.
class AuditLog < ApplicationRecord
  self.table_name = "audit_log"

  STATUSES = %w[success unauthorized param_invalid unknown_template].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :caller_id, presence: true, length: { maximum: 128 }
end
