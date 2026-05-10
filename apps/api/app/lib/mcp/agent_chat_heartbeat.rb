# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Mcp::AgentChatHeartbeat — émet `event: ping` toutes les `interval_s`
# secondes dans un IO writable, jusqu'à `stop` ou fermeture du stream.
#
# Cf. openspec/changes/add-agent-chat-streaming/specs/mcp-server/spec.md
#   -> Requirement: Agent Chat SSE Heartbeat
#
# But : éviter les timeouts intermédiaires (reverse proxy, load balancer,
# navigateur) sur les retrievals lents (1-3 s avec embedder externe).
# Le ping est un keep-alive pur — pas de donnée applicative — que les
# SDK SSE ignorent par défaut.
#
# Implémentation : un Thread Ruby simple. Le Thread vérifie
# `stream.closed?` avant chaque write pour ne pas crasher sur un
# client gone. Toute exception réseau (`IOError`, `Errno::EPIPE`) est
# rattrapée silencieusement — l'arrêt naturel de la connexion n'est pas
# une erreur applicative.

module Mcp
  module AgentChatHeartbeat
    PING_PAYLOAD = "event: ping\ndata: {}\n\n"

    module_function

    # start :
    #   - retourne nil si interval_s ≤ 0 (heartbeat désactivé)
    #   - sinon retourne un Thread qui pousse un ping toutes les interval_s
    def start(stream:, interval_s:)
      return nil if interval_s.to_f <= 0

      Thread.new do
        loop do
          sleep interval_s
          break if stream.closed?

          stream.write(PING_PAYLOAD)
        rescue IOError, Errno::EPIPE
          break
        end
      end
    end

    # stop : annule proprement le thread sans bloquer si la `kill` rate.
    def stop(thread)
      return if thread.nil?

      thread.kill
      thread.join(0.1)
    rescue StandardError
      # Pas remontable : kill d'un thread déjà mort est tolérable.
    end
  end
end
