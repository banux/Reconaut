# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

module Scanner
  # Résultat partagé entre les use cases Scanner (ClaimJob / SubmitResult /
  # FailJob). Encapsule un status sémantique et le body de réponse.
  #
  # Cf. openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
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
