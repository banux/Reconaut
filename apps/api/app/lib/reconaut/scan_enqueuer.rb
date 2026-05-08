# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"
require_relative "../job_schema/registry"

module Reconaut
  # ScanEnqueuer : verifie le scope, valide le payload contre
  # ScanJobV1, calcule une cle d'idempotence stable, persiste un
  # placeholder de job (delegue au job_bus injectable). Renvoie un
  # `scan_id` correlationnable.
  #
  # Source de verite :
  #   openspec/changes/init-reconaut-platform/specs/mcp-server/spec.md
  #     -> request_scan
  #   openspec/changes/init-reconaut-platform/tasks.md section 5.2
  #   openspec/changes/add-tech-stack/specs/architecture/spec.md
  #     -> Demande de scan se materialise comme un job GoodJob
  #
  # Le `job_bus` est un objet repondant a `enqueue(payload:)`
  # -> { scan_id, idempotency_key }. Implementations :
  #   - InMemory (utile en tests)
  #   - GoodJob (a livrer dans add-tech-stack 5.1, ScanJob.perform_later)
  class ScanEnqueuer
    class OutOfScopeError < StandardError; end
    class InvalidPayloadError < StandardError; end
    class InvalidTargetError < StandardError; end

    SUPPORTED_KINDS = %w[ip cidr domain host].freeze

    # Contraintes par scan_kind : certains scanners n'acceptent qu'un
    # sous-ensemble de target_kind. dns_records (cf. add-dns-records-scanner)
    # n'a de sens que sur un domaine ou un host — résoudre les records
    # DNS d'une IP ou d'un CIDR n'a pas de sens.
    SCAN_KIND_TARGET_CONSTRAINTS = {
      "dns_records" => %w[domain host].freeze
    }.freeze

    Result = Struct.new(:scan_id, :idempotency_key, keyword_init: true) do
      def to_h = { scan_id: scan_id, idempotency_key: idempotency_key }
    end

    def initialize(scope_storage:, job_bus:, scan_store: nil)
      @scope_storage = scope_storage
      @job_bus       = job_bus
      @scan_store    = scan_store
    end

    def call(scan_kind:, target_kind:, target_value:, options: {}, requested_at: Time.now.utc)
      ensure_target_kind_allowed!(scan_kind, target_kind)
      ensure_in_scope!(target_kind, target_value)
      payload = build_payload(scan_kind, target_kind, target_value, options, requested_at)
      validate_payload!(payload)

      result   = @job_bus.enqueue(payload: payload)
      scan_id  = result.fetch(:scan_id)
      idem_key = payload["idempotency_key"]

      @scan_store&.record!(
        scan_id:         scan_id,
        scan_kind:       scan_kind,
        target_kind:     target_kind,
        target_value:    target_value,
        idempotency_key: idem_key,
        enqueued_at:     requested_at
      )

      Result.new(
        scan_id:         scan_id,
        idempotency_key: idem_key
      )
    end

    # Vérifie qu'un scan_kind avec contraintes spécifiques sur le
    # target_kind respecte ces contraintes. Cf.
    # SCAN_KIND_TARGET_CONSTRAINTS et openspec/changes/add-dns-records-scanner/.
    def ensure_target_kind_allowed!(scan_kind, target_kind)
      allowed = SCAN_KIND_TARGET_CONSTRAINTS[scan_kind.to_s]
      return if allowed.nil? # pas de contrainte, on accepte tous les target_kind valides du schema

      return if allowed.include?(target_kind.to_s)

      raise InvalidTargetError,
            "#{scan_kind} requires target_kind in {#{allowed.join(', ')}}, got #{target_kind}"
    end

    # Scope check : la cible DOIT correspondre a au moins un scope
    # autorise. Pour la v1, on fait un match simple (kind == target_kind
    # ET value == target_value). Les sous-domaines / sous-reseaux seront
    # gerees dans une iteration ulterieure (cf. init-reconaut-platform 2.3).
    def ensure_in_scope!(kind, value)
      authorized = @scope_storage.list.any? do |scope|
        scope.kind.to_s == kind.to_s && scope.value.to_s == value.to_s
      end
      return if authorized

      raise OutOfScopeError,
            "out-of-scope: #{kind}:#{value} n'est pas dans la liste declaree"
    end

    private

    def build_payload(scan_kind, target_kind, target_value, options, requested_at)
      {
        "schema_version"  => 1,
        "idempotency_key" => idempotency_key(target_kind, target_value, requested_at),
        "scan_kind"       => scan_kind.to_s,
        "target"          => { "kind" => target_kind.to_s, "value" => target_value.to_s },
        "requested_at"    => requested_at.iso8601,
        "options"         => options || {}
      }.tap { |h| h.delete("options") if h["options"].empty? }
    end

    # Cle deterministe = "scan-YYYYMMDD-HHMM-<hash>". Garantit que deux
    # appels dans la meme minute pour la meme cible se collapsent.
    def idempotency_key(target_kind, target_value, requested_at)
      bucket = requested_at.strftime("%Y%m%d-%H%M")
      digest = Digest::SHA256.hexdigest("#{target_kind}|#{target_value}")[0, 16]
      "scan-#{bucket}-#{digest}"
    end

    def validate_payload!(payload)
      ok, errors = JobSchema::Registry.validate("ScanJobV1", payload)
      raise InvalidPayloadError, errors.join("; ") unless ok
    end

    # Petit job_bus en memoire pour les tests + le dev local. La v1
    # GoodJob livrera un JobBus qui appelle `ScanJob.perform_later` ;
    # son contrat est le meme : `enqueue(payload:) -> { scan_id: ... }`.
    class InMemoryJobBus
      def initialize
        @jobs = []
        @mutex = Mutex.new
      end

      def enqueue(payload:)
        scan_id = SecureRandom.uuid
        @mutex.synchronize { @jobs << { scan_id: scan_id, payload: payload } }
        { scan_id: scan_id }
      end

      def jobs = @mutex.synchronize { @jobs.dup }
      def size = @mutex.synchronize { @jobs.size }
      def clear! = @mutex.synchronize { @jobs.clear }
    end
  end
end
