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

  # Indexation embedding asynchrone — cf. add-embedding-pipeline.
  # Trigger sur create et sur update qui touche un champ embedding-pertinent.
  # NB : on déclare deux callbacks via blocs anonymes pour éviter que
  # ActiveRecord ne consolide les deux `enqueue_embedding_index!` avec
  # leurs filtres `:if` distincts.
  EMBEDDING_RELEVANT_COLS = %w[ip fqdn last_seen_at].freeze

  after_create_commit { enqueue_embedding_index! }
  after_update_commit { enqueue_embedding_index! if embedding_relevant_changes? }

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

  # enqueue_embedding_index! : pousse un IndexHostJob qui vectorise
  # l'hôte en arrière-plan. Si GoodJob n'est pas câblé (specs unitaires
  # qui ne montent pas la file), on swallow — la spec qui veut tester
  # l'enqueue utilise ActiveJob::TestHelper.
  def enqueue_embedding_index!
    return unless defined?(::IndexHostJob)

    ::IndexHostJob.perform_later(id)
  rescue StandardError => e
    Rails.logger&.warn("[embedding] enqueue failed for host=#{id}: #{e.class}: #{e.message}")
  end

  # embedding_relevant_changes? : true si une colonne du fingerprint
  # vient de changer dans l'update qui se commit.
  def embedding_relevant_changes?
    (saved_changes.keys & EMBEDDING_RELEVANT_COLS).any?
  end
end
