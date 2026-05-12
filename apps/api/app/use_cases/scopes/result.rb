# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

module Scopes
  # Résultat partagé entre les use cases Scopes (List/Add/Revoke).
  # Encapsule un status sémantique et le body de réponse ; la traduction
  # vers HTTP est faite par #http_status.
  Result = Struct.new(:status, :body, keyword_init: true) do
    HTTP_MAP = {
      ok:           200,
      created:      201,
      no_content:   204,
      bad_request:  400,
      not_found:    404
    }.freeze

    def http_status
      HTTP_MAP.fetch(status, 500)
    end
  end
end
