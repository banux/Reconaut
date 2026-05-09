# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Service : un (host, port, protocol) observé à un instant `scanned_at`.
# Stocké dans une hypertable TimescaleDB partitionnée sur `scanned_at`
# (chunks 1 jour, rétention 90 j).
# Cf. openspec/changes/init-reconaut-platform/specs/scanning/spec.md
# (Requirement: Port and Service Fingerprinting + Retention).
class Service < ApplicationRecord
  PROTOCOLS = %w[tcp udp].freeze
  OUTCOMES  = %w[success timeout reset tls_error other].freeze

  belongs_to :host

  validates :port, presence: true, numericality: {
    only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535
  }
  validates :protocol, inclusion: { in: PROTOCOLS }
  validates :outcome,  inclusion: { in: OUTCOMES }
  validates :scanned_at, presence: true

  # Hypertable Timescale : la PK composée (id, scanned_at) est
  # nécessaire à Timescale (la colonne de partitionnement DOIT figurer
  # dans la PK).
  self.primary_key = [:id, :scanned_at]
end
