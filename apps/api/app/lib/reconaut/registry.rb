# frozen_string_literal: true

require_relative "../agent/audit_recorder"
require_relative "../../use_cases/scopes/storage"
require_relative "scan_enqueuer"

# Registry singleton : assemble les dependances que les controllers
# utilisent (HybridRetriever, ScopeStorage, AuditRecorder, ScanEnqueuer)
# en un seul endroit configurable.
#
# En tests, on instancie une registry locale et on l'injecte dans le
# use case ; en prod, le controller passe par Reconaut::Registry.default.
module Reconaut
  class Registry
    attr_accessor :hybrid_retriever, :scope_storage, :audit_recorder, :job_bus

    def initialize
      @audit_recorder  = ::Agent::AuditRecorder::InMemoryRecorder.new
      @scope_storage   = ::Scopes::Storage::InMemory.new
      @hybrid_retriever = nil # cable au boot via un initializer dedie
                              # quand HybridRetriever est pret a tourner
                              # contre Postgres+AGE.
      @job_bus         = ::Reconaut::ScanEnqueuer::InMemoryJobBus.new
    end

    def scan_enqueuer
      ::Reconaut::ScanEnqueuer.new(scope_storage: scope_storage, job_bus: job_bus)
    end

    @default = nil
    @mutex   = Mutex.new

    class << self
      def default
        @mutex.synchronize { @default ||= new }
      end

      def reset!
        @mutex.synchronize { @default = nil }
      end
    end
  end
end
