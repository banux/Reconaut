# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "storage"
require_relative "result"

module Scopes
  # En mode mono-user (cf. openspec/changes/single-user-only/), il n'y
  # a plus de notion de rôle. Le contrôle d'accès vit (a) au niveau
  # MCP scope (Mcp::Tool#call vérifie `caller_scopes`), et (b) à
  # l'authentification (la présence d'une clé API valide). Les use
  # cases ne ré-implémentent plus la matrice — ils prennent juste
  # `caller_id:` pour l'audit.
  class List
    def initialize(storage:)
      @storage = storage
    end

    def call(caller_id: "anonymous")
      _ = caller_id # réservé à l'audit éventuel ; la lecture n'est pas auditée
      Result.new(
        status: :ok,
        body: { scopes: @storage.list.map(&:to_h) }
      )
    end
  end
end
