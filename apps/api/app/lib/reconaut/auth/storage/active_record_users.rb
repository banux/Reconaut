# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Adapter Postgres-backed du store des `users`. Implémente la même
# interface que `Reconaut::Auth::Storage::InMemoryUsers` mais persiste
# via `Reconaut::Auth::ArUser`.
#
# Cf. openspec/changes/add-persistent-auth-storage/specs/platform/spec.md
#   -> Requirement: Backend de stockage auth interchangeable
#
# Le constructeur n'a pas de paramètre. Le mapping AR → Struct conserve
# le format ISO-8601 UTC pour `created_at` et `disabled_at` afin d'être
# octet-pour-octet identique au backend in-memory.

module Reconaut
  module Auth
    module Storage
      class ActiveRecordUsers
        # En mode mono-user, role est ignoré (kept pour rétrocompat).
        def create(email:, password_hash:, role: nil)
          _ = role
          email = normalize_email(email)
          ar = ar_model.create!(email: email, password_hash: password_hash)
          to_struct(ar)
        rescue ActiveRecord::RecordNotUnique
          raise ArgumentError, "email_taken"
        end

        def find_by_email(email)
          email = normalize_email(email)
          ar = ar_model.find_by(email: email)
          ar && to_struct(ar)
        end

        def find(id)
          ar = ar_model.find_by(id: id)
          ar && to_struct(ar)
        end

        def list
          ar_model.order(:created_at).map { |ar| to_struct(ar) }
        end

        def set_password_hash!(id, password_hash)
          ar = ar_model.find_by(id: id)
          return nil unless ar

          ar.update!(password_hash: password_hash)
          to_struct(ar)
        end

        def disable!(id)
          ar = ar_model.find_by(id: id)
          return nil unless ar

          ar.update!(disabled_at: Time.now.utc) if ar.disabled_at.nil?
          to_struct(ar)
        end

        private

        def ar_model
          ::Reconaut::Auth::ArUser
        end

        def normalize_email(email)
          e = email.to_s.downcase.strip
          raise ArgumentError, "invalid_email" if e.empty? || !e.include?("@")

          e
        end

        def to_struct(ar)
          User.new(
            id:            ar.id,
            email:         ar.email.to_s,
            password_hash: ar.password_hash,
            created_at:    iso8601(ar.created_at),
            disabled_at:   iso8601(ar.disabled_at)
          )
        end

        def iso8601(value)
          return nil if value.nil?

          value.utc.iso8601
        end
      end
    end
  end
end
