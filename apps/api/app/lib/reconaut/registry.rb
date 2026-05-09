# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "../agent/audit_recorder"
require_relative "../../use_cases/scopes/storage"
require_relative "scan_enqueuer"
require_relative "auth/storage"
require_relative "auth/authenticator"
require_relative "auth/password_hasher"
require_relative "heartbeats"
require_relative "scans"

# Registry singleton : assemble les dependances que les controllers
# utilisent (HybridRetriever, ScopeStorage, AuditRecorder, ScanEnqueuer,
# Authenticator) en un seul endroit configurable.
#
# En tests, on instancie une registry locale et on l'injecte dans le
# use case ; en prod, le controller passe par Reconaut::Registry.default.
module Reconaut
  class Registry
    attr_accessor :hybrid_retriever, :scope_storage, :audit_recorder, :job_bus,
                  :user_store, :api_key_store, :password_hasher, :heartbeat_store,
                  :scan_store

    def initialize
      @audit_recorder   = ::Agent::AuditRecorder::InMemoryRecorder.new
      @scope_storage    = ::Scopes::Storage::InMemory.new
      @hybrid_retriever = nil
      @job_bus          = ::Reconaut::ScanEnqueuer::InMemoryJobBus.new
      @user_store, @api_key_store = wire_auth_stores
      @heartbeat_store  = ::Reconaut::Heartbeats::InMemoryStore.new
      @scan_store       = ::Reconaut::Scans::InMemoryStore.new
      # Plain par defaut pour ne pas faire payer Argon2 sur chaque test
      # qui boote la registry. Les specs auth qui veulent le hash reel
      # remplacent password_hasher par PasswordHasher::Argon2id.new.
      @password_hasher  = ::Reconaut::Auth::PasswordHasher::Plain.new
    end

    # Choisit le backend de stockage auth selon l'état de la connexion
    # ActiveRecord :
    #   - prod / dev / specs DB-bound : ActiveRecord (table users existe)
    #   - tests rapides sans DB câblée : InMemory (fallback)
    #
    # Cf. openspec/changes/add-persistent-auth-storage/specs/platform/spec.md
    #   -> Requirement: Backend de stockage auth interchangeable
    def wire_auth_stores
      if active_record_auth_ready?
        [::Reconaut::Auth::Storage::ActiveRecordUsers.new,
         ::Reconaut::Auth::Storage::ActiveRecordApiKeys.new]
      else
        [::Reconaut::Auth::Storage::InMemoryUsers.new,
         ::Reconaut::Auth::Storage::InMemoryApiKeys.new]
      end
    end

    def active_record_auth_ready?
      return false unless defined?(ActiveRecord::Base)

      # On NE pré-teste PAS `connected?` : la connexion AR est lazy en
      # Rails 8 (établie au premier query). Une tentative directe via
      # `table_exists?` ouvre la connexion ; on rattrape les erreurs
      # de connexion / DB inexistante pour retomber sur l'in-memory
      # côté test sans DB.
      ActiveRecord::Base.connection.table_exists?(:users)
    rescue ActiveRecord::ActiveRecordError, PG::Error
      false
    end

    def scan_enqueuer
      ::Reconaut::ScanEnqueuer.new(
        scope_storage: scope_storage,
        job_bus:       job_bus,
        scan_store:    scan_store
      )
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
