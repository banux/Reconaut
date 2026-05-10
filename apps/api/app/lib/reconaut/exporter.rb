# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "json"
require "csv"
require "digest"
require "securerandom"

# Reconaut::Exporter — sérialise un sous-ensemble des données (scope,
# hosts, services, scans) dans l'un des trois formats `json`, `csv`,
# `stix2`. Pas de gem externe : stdlib uniquement.
#
# Cf. openspec/changes/add-mcp-engine/specs/mcp-server/spec.md
#   -> Requirement: MCP Tool `export_report`
#
# Le STIX2 produit est minimal — bundle de SCO (`ipv4-addr`,
# `domain-name`, `network-traffic`). Pas de mapping `indicator` /
# `relationship` / `sighting` (différé à `add-stix2-full-mapping`).
module Reconaut
  module Exporter
    ALLOWED_KINDS   = %w[scope hosts services scans].freeze
    ALLOWED_FORMATS = %w[json csv stix2].freeze
    DEFAULT_LIMIT   = 1000
    MAX_LIMIT       = 10_000

    # Namespace UUID5 figé pour cohérence inter-export des id STIX
    # (le même host produit toujours le même `ipv4-addr--<uuid5>`).
    STIX_UUID_NAMESPACE = "00000000-0000-0000-0000-reconaut0001"

    Result = Struct.new(:path, :record_count, :format, :kind, keyword_init: true)

    class InvalidParamError < StandardError; end

    module_function

    # export : génère le fichier sous `dest_dir/<uuid>.<ext>` et
    # retourne un Result. Charge les records via les stores Registry
    # par défaut (mode prod) ; les tests injectent leur propre data
    # source via le param `data:` (Hash {scope:, hosts:, services:,
    # scans:} d'Arrays).
    def export(kind:, format:, dest_dir:, limit: DEFAULT_LIMIT, data: nil)
      kind   = kind.to_s.downcase
      format = format.to_s.downcase
      raise InvalidParamError, "invalid kind=#{kind.inspect}"     unless ALLOWED_KINDS.include?(kind)
      raise InvalidParamError, "invalid format=#{format.inspect}" unless ALLOWED_FORMATS.include?(format)

      limit = clamp_limit(limit)

      records = fetch_records(kind: kind, limit: limit, data: data)
      uuid    = SecureRandom.uuid
      ext     = format == "stix2" ? "json" : format
      path    = File.join(dest_dir, "#{uuid}.#{ext}")
      FileUtils.mkdir_p(dest_dir)

      payload = serialize(records: records, kind: kind, format: format)
      File.write(path, payload)

      Result.new(
        path:         path,
        record_count: records.size,
        format:       format,
        kind:         kind
      )
    end

    # content_type : retourne le Content-Type adapté au format.
    def content_type(format)
      case format.to_s
      when "json"  then "application/json"
      when "csv"   then "text/csv"
      when "stix2" then "application/stix+json;version=2.1"
      else "application/octet-stream"
      end
    end

    # purge_older_than! : supprime les fichiers d'export plus vieux
    # que `older_than` secondes. Idempotent. Appelé à chaque nouvelle
    # génération pour éviter l'accumulation de fichiers orphelins
    # (download abandonné, crash). Pas de cron dédié.
    def purge_older_than!(dir:, older_than:)
      return unless Dir.exist?(dir)

      cutoff = Time.now - older_than
      Dir.glob(File.join(dir, "*.{json,csv}")).each do |f|
        File.unlink(f) if File.mtime(f) < cutoff
      rescue StandardError
        # Best-effort — un fichier qu'on n'arrive pas à supprimer
        # (race avec un download concurrent) sera nettoyé au prochain
        # passage.
      end
    end

    # ---- privé ---------------------------------------------------------

    def clamp_limit(limit)
      n = Integer(limit)
      return DEFAULT_LIMIT if n <= 0

      [n, MAX_LIMIT].min
    end

    def fetch_records(kind:, limit:, data:)
      if data
        Array(data[kind.to_sym] || data[kind]).first(limit)
      else
        case kind
        when "scope"
          ::ScanScopeEntry.where(revoked_at: nil)
                          .order(:created_at)
                          .limit(limit)
                          .map { |e| e.attributes.symbolize_keys }
        when "hosts"
          ::Host.order(:created_at).limit(limit).map { |h| h.attributes.symbolize_keys }
        when "services"
          ::Service.order(:scanned_at).limit(limit).map { |s| s.attributes.symbolize_keys.except(:tls_cert_der) }
        when "scans"
          ::Reconaut::Registry.default.scan_store.list(limit: limit).map { |s| s.is_a?(Hash) ? s : s.to_h }
        end
      end
    end

    def serialize(records:, kind:, format:)
      case format
      when "json"  then JSON.pretty_generate(records)
      when "csv"   then to_csv(records)
      when "stix2" then to_stix2(records: records, kind: kind)
      end
    end

    def to_csv(records)
      return "" if records.empty?

      headers = records.first.keys.map(&:to_s)
      CSV.generate do |csv|
        csv << headers
        records.each do |r|
          csv << headers.map { |h| stringify(r[h.to_sym] || r[h]) }
        end
      end
    end

    def stringify(v)
      case v
      when nil           then ""
      when Hash, Array   then JSON.generate(v)
      else v.to_s
      end
    end

    def to_stix2(records:, kind:)
      objects = case kind
                when "hosts"    then stix2_from_hosts(records)
                when "services" then stix2_from_services(records)
                when "scope"    then stix2_from_scope(records)
                when "scans"    then stix2_from_scans(records)
                else []
                end

      bundle = {
        type:    "bundle",
        id:      "bundle--#{SecureRandom.uuid}",
        objects: objects
      }
      JSON.pretty_generate(bundle)
    end

    def stix2_from_hosts(hosts)
      out = []
      hosts.each do |h|
        if h[:ip] && !h[:ip].to_s.empty?
          out << {
            type:  "ipv4-addr",
            id:    "ipv4-addr--#{uuid5(h[:ip])}",
            value: h[:ip].to_s
          }
        end
        if h[:fqdn] && !h[:fqdn].to_s.empty?
          out << {
            type:  "domain-name",
            id:    "domain-name--#{uuid5(h[:fqdn])}",
            value: h[:fqdn].to_s
          }
        end
      end
      out
    end

    def stix2_from_services(services)
      services.map do |s|
        {
          type:      "network-traffic",
          id:        "network-traffic--#{uuid5("#{s[:host_id]}:#{s[:port]}/#{s[:protocol]}")}",
          dst_port:  s[:port].to_i,
          protocols: [s[:protocol].to_s].compact
        }
      end
    end

    def stix2_from_scope(entries)
      entries.map do |e|
        kind = e[:kind].to_s
        type, value = case kind
                      when "domain"      then ["domain-name", e[:value]]
                      when "host"        then ["domain-name", e[:value]]
                      when "cidr", "ip"  then ["ipv4-addr",  e[:value]]
                      else ["x-reconaut-scope", e[:value]]
                      end
        { type: type, id: "#{type}--#{uuid5(value.to_s)}", value: value.to_s }
      end
    end

    def stix2_from_scans(scans)
      # Les scans n'ont pas de correspondance SCO directe ; on
      # produit un objet `x-reconaut-scan` (extension custom) qui
      # référence target_kind/target_value. Conforme à l'extensibilité
      # STIX2 (préfixe `x-`).
      scans.map do |s|
        {
          type:         "x-reconaut-scan",
          id:           "x-reconaut-scan--#{uuid5(s[:idempotency_key].to_s)}",
          scan_kind:    s[:scan_kind],
          target_kind:  s[:target_kind],
          target_value: s[:target_value],
          status:       s[:status]
        }
      end
    end

    # uuid5 déterministe — mêmes inputs produisent le même UUID, ce
    # qui garantit la cohérence inter-export (même host = même id STIX).
    def uuid5(input)
      hash = Digest::SHA1.hexdigest("#{STIX_UUID_NAMESPACE}#{input}")
      [
        hash[0, 8],
        hash[8, 4],
        "5#{hash[13, 3]}",
        "#{(hash[16, 2].to_i(16) & 0x3f | 0x80).to_s(16)}#{hash[18, 2]}",
        hash[20, 12]
      ].join("-")
    end
  end
end
