# frozen_string_literal: true

require "ipaddr"
require "resolv"

# ScanScopeEntry : périmètre déclaré explicitement par l'opérateur.
# Cf. openspec/changes/init-reconaut-platform/specs/scanning/spec.md
# (Requirement: Scope Declaration and Enforcement).
#
# Trois formes : `cidr`, `domain`, `host` (un host est typiquement un
# FQDN avec un nom plus précis qu'un domaine — ex. `mail.example.fr`).
#
# Append-only : on ne supprime jamais, on `revoke!` (pose `revoked_at`)
# pour conserver la traçabilité dans l'audit.
class ScanScopeEntry < ApplicationRecord
  KINDS = %w[cidr domain host].freeze

  validates :kind, inclusion: { in: KINDS, message: "must be one of #{KINDS.join(', ')}" }
  validates :value, presence: true, length: { maximum: 255 }
  validates :created_by, presence: true, length: { maximum: 128 }
  validate  :value_matches_kind

  scope :active, -> { where(revoked_at: nil) }

  # Marque l'entrée comme révoquée. Idempotent : un second appel ne
  # change pas le `revoked_at` initial.
  def revoke!(at: Time.now.utc)
    return self if revoked?

    update!(revoked_at: at)
    self
  end

  def revoked?
    !revoked_at.nil?
  end

  # Vérifie qu'une cible (kind + value) est couverte par cette entrée.
  # Match strict pour `host` et `domain` (égalité). Pour `cidr`, on
  # teste l'inclusion réseau de la cible (qui doit être `ip` ou
  # `cidr` lui-même).
  def covers?(target_kind, target_value)
    return false if revoked?
    return false if target_value.to_s.strip.empty?

    case kind
    when "cidr"
      cidr_covers?(target_kind, target_value)
    when "domain"
      target_kind.to_s == "domain" && target_value.to_s == value
    when "host"
      target_kind.to_s == "host" && target_value.to_s == value
    end
  end

  private

  def cidr_covers?(target_kind, target_value)
    return false unless %w[ip cidr host].include?(target_kind.to_s)

    network = IPAddr.new(value)
    target = case target_kind.to_s
             when "ip", "host" then IPAddr.new(target_value)
             when "cidr"       then IPAddr.new(target_value)
             end
    network.include?(target)
  rescue IPAddr::Error
    false
  end

  def value_matches_kind
    return if value.blank? || kind.blank?

    case kind
    when "cidr"
      validate_cidr
    when "domain", "host"
      validate_dns_name
    end
  end

  def validate_cidr
    IPAddr.new(value)
  rescue IPAddr::Error
    errors.add(:value, "is not a valid CIDR (#{value.inspect})")
  end

  # Domaine/host : caractères DNS standards, longueur ≤ 255, pas
  # d'espaces, etc. On reste laxiste — c'est l'opérateur qui valide
  # son périmètre, pas une RFC stricte.
  def validate_dns_name
    return if value.match?(/\A[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?)*\z/i)

    errors.add(:value, "is not a valid DNS name (#{value.inspect})")
  end
end
