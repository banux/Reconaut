# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Host : cible identifiée par son IP et/ou son FQDN. Au moins un des
# deux doit être présent (contrainte SQL `hosts_at_least_one_identifier`).
# Cf. openspec/changes/init-reconaut-platform/specs/scanning/spec.md.
class Host < ApplicationRecord
  has_many :services, dependent: :destroy

  validates :ip, presence: { unless: :fqdn? }
  validates :fqdn, length: { maximum: 255 }, allow_nil: true
  validate :ip_or_fqdn_present

  # Met à jour `last_seen_at` à `now()`. Utile à chaque ingestion d'un
  # nouveau résultat de scan ciblant cet hôte.
  def touch_seen!(at: Time.now.utc)
    update!(last_seen_at: at)
  end

  private

  def fqdn?
    fqdn.present?
  end

  def ip_or_fqdn_present
    return if ip.present? || fqdn.present?

    errors.add(:base, "host must have at least one of ip or fqdn")
  end
end
