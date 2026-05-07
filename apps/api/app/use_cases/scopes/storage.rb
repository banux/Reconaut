# frozen_string_literal: true

require "securerandom"

module Scopes
  # Interface de stockage des scopes d'autorisation. La v1 livre une
  # implementation en memoire, suffisante pour les use cases unitaires
  # et le dev local. Une implementation ActiveRecord arrivera quand le
  # modele Scope sera cree par init-reconaut-platform.
  #
  # Cf. openspec/changes/init-reconaut-platform/tasks.md section 2.4
  # ("Endpoints POST /scopes, DELETE /scopes/{id}").
  module Storage
    Scope = Struct.new(:id, :kind, :value, :created_at, keyword_init: true) do
      def to_h
        { id: id, kind: kind, value: value, created_at: created_at }
      end
    end

    VALID_KINDS = %w[domain ip cidr host].freeze

    class InMemory
      def initialize
        @scopes = {}
        @mutex = Mutex.new
      end

      def list
        @mutex.synchronize { @scopes.values.map(&:dup).map(&:freeze) }
      end

      def create(kind:, value:)
        kind = kind.to_s
        value = value.to_s.strip
        raise ArgumentError, "invalid_kind"  unless VALID_KINDS.include?(kind)
        raise ArgumentError, "value_required" if value.empty?

        scope = Scope.new(
          id:         SecureRandom.uuid,
          kind:       kind,
          value:      value,
          created_at: Time.now.utc.iso8601
        )
        @mutex.synchronize { @scopes[scope.id] = scope }
        scope
      end

      def delete(id)
        @mutex.synchronize { @scopes.delete(id) }
      end
    end
  end
end
