# frozen_string_literal: true

require_relative "../agent/audit_recorder"
require_relative "../../use_cases/scopes/storage"
require_relative "scan_enqueuer"
require_relative "auth/storage"
require_relative "auth/authenticator"
require_relative "auth/password_hasher"
require_relative "heartbeats"

# Registry singleton : assemble les dependances que les controllers
# utilisent (HybridRetriever, ScopeStorage, AuditRecorder, ScanEnqueuer,
# Authenticator) en un seul endroit configurable.
#
# En tests, on instancie une registry locale et on l'injecte dans le
# use case ; en prod, le controller passe par Reconaut::Registry.default.
module Reconaut
  class Registry
    attr_accessor :hybrid_retriever, :scope_storage, :audit_recorder, :job_bus,
                  :user_store, :api_key_store, :password_hasher, :heartbeat_store

    def initialize
      @audit_recorder   = ::Agent::AuditRecorder::InMemoryRecorder.new
      @scope_storage    = ::Scopes::Storage::InMemory.new
      @hybrid_retriever = nil
      @job_bus          = ::Reconaut::ScanEnqueuer::InMemoryJobBus.new
      @user_store       = ::Reconaut::Auth::Storage::InMemoryUsers.new
      @api_key_store    = ::Reconaut::Auth::Storage::InMemoryApiKeys.new
      @heartbeat_store  = ::Reconaut::Heartbeats::InMemoryStore.new
      # Plain par defaut pour ne pas faire payer Argon2 sur chaque test
      # qui boote la registry. Les specs auth qui veulent le hash reel
      # remplacent password_hasher par PasswordHasher::Argon2id.new.
      @password_hasher  = ::Reconaut::Auth::PasswordHasher::Plain.new
    end

    def scan_enqueuer
      ::Reconaut::ScanEnqueuer.new(scope_storage: scope_storage, job_bus: job_bus)
    end

    def authenticator
      ::Reconaut::Auth::Authenticator.new(
        user_store:      user_store,
        api_key_store:   api_key_store,
        password_hasher: password_hasher
      )
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
