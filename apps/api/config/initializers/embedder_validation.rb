# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Valide la config embedder au boot Rails. En production / development,
# une misconfiguration (provider inconnu, variable manquante)
# fait échouer le boot avec un message explicite — l'opérateur
# voit immédiatement le problème dans les logs ou le crashloop du
# container, plutôt que de découvrir le 500 à la première requête
# `/agent/chat`.
#
# Cf. openspec/changes/add-embedder-pluggable/specs/agent-interface/spec.md
#   -> Requirement: Boot Validation of Embedder Configuration
#
# En `test`, on n'échoue pas — les specs injectent leurs propres
# embedders via Registry.default.user_store = ... et n'ont pas besoin
# d'une config env complète.

return if Rails.env.test?

Rails.application.config.after_initialize do
  embedder = Reconaut::Embedder.build(env: ENV)
  Rails.logger.info(
    "[embedder] provider=#{embedder.provider} dim=#{embedder.dim}"
  )
rescue Reconaut::Embedder::MisconfiguredError => e
  warn "[embedder] FATAL embedder-misconfigured : #{e.message}"
  warn "[embedder] Le boot Rails est interrompu — corrigez RECONAUT_EMBEDDER_* puis relancez."
  abort("embedder-misconfigured")
end
