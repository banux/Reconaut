# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Circuit breaker minimaliste utilisé par Reconaut::Embedder::Resilient.
#
# États : :closed → :open → :half_open → :closed (succès) ou :open (échec).
#
#   - :closed     — tout passe ; chaque échec est compté dans la fenêtre
#                   glissante. Au-delà de N échecs en window_s secondes,
#                   bascule à :open.
#   - :open       — refus immédiat ; pendant open_s secondes, chaque
#                   appel lève sans toucher au backend. Au-delà, bascule
#                   à :half_open.
#   - :half_open  — un appel d'essai est autorisé. Succès → :closed
#                   (compteurs reset). Échec → :open (nouveau cycle de
#                   open_s secondes).
#
# Pas de mutex : Ruby GIL protège les opérations atomiques sur Array,
# et le wrapper est instancié par Registry (un seul par process) ; les
# requêtes Rails qui partagent l'instance ne courent qu'un risque de
# léger off-by-one sur le compteur d'échecs — acceptable.
#
# Cf. openspec/changes/add-embedder-pluggable/specs/agent-interface/spec.md
#   -> Requirement: Embedder Resilience
module Reconaut
  module Embedder
    class Breaker
      attr_reader :failures_count, :opened_at, :failures_threshold,
                  :window_s, :open_s

      def initialize(failures:, window_s:, open_s:, clock: -> { Time.now })
        @failures_threshold = failures
        @window_s           = window_s
        @open_s             = open_s
        @clock              = clock
        @failures           = [] # Array<Time> — timestamps des échecs récents
        @opened_at          = nil
        @half_open_in_progress = false
      end

      # state retourne le state effectif COMPTE TENU du temps écoulé.
      # Lecture pure (n'altère pas l'état interne).
      def state
        if @opened_at
          if @clock.call - @opened_at >= @open_s
            :half_open
          else
            :open
          end
        else
          :closed
        end
      end

      # open? est `true` SSI le circuit est dans :open au sens strict
      # (pas dans :half_open). Utilisé par Resilient pour court-circuiter
      # immédiatement les appels.
      def open?
        state == :open
      end

      def closed?
        state == :closed
      end

      def half_open?
        state == :half_open
      end

      def record_failure!
        now = @clock.call
        if half_open?
          # Échec en half_open → réouvre le circuit pour open_s secondes.
          @opened_at = now
          @failures = []
          return
        end

        # En :closed (ou expiré au-delà de window_s) : on ajoute le
        # timestamp et on prune les échecs hors fenêtre.
        @failures << now
        @failures.reject! { |t| now - t > @window_s }

        if @failures.size >= @failures_threshold
          @opened_at = now
          @failures = []
        end
      end

      def record_success!
        if half_open?
          @opened_at = nil
          @failures  = []
        elsif closed?
          # Succès en closed : on ne touche pas aux compteurs (les
          # échecs anciens vont expirer naturellement par window_s).
        end
      end

      # failures_count expose le nombre d'échecs actuellement comptés
      # dans la fenêtre glissante (utile pour le doctor et les tests).
      def failures_count
        return 0 if @opened_at # quand ouvert, on a déjà reset

        now = @clock.call
        @failures.count { |t| now - t <= @window_s }
      end
    end
  end
end
