# frozen_string_literal: true

require "time"

module Reconaut
  # GraphProjector : projette un `ScanResultV1` validé vers le graphe
  # Apache AGE. Pur SQL Cypher (MERGE idempotent), aucune extraction
  # LLM, aucun appel sortant.
  #
  # Source de vérité :
  #   openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md
  #     -> Requirement: Asset Graph Projection
  #   openspec/changes/add-graph-retrieval/tasks.md §2.1, §2.2
  #
  # Convention sur les findings (à raffiner quand `scan-engine-<protocol>`
  # livrera un schéma typé) :
  #
  #   - finding.port            → nœud Service {host_id, port, protocol}
  #                              + arête EXPOSES (Host → Service)
  #   - finding.tls_cert_sha256 → nœud Certificate {sha256}
  #                              + arête PRESENTS (Host → Certificate)
  #   - finding.record_type ∈ A/AAAA + finding.value
  #                            → nœud Host {id=value}
  #                              + arête RESOLVES_TO (Domain → Host)
  #
  # Le label racine est dérivé de `target.kind` : `host` → Host{id=value},
  # `domain` → Domain{name=value}, `ip`/`cidr` ne projettent pas (pas
  # de label canonique pour ces formes en v1).
  module GraphProjector
    GRAPH_NAME = "reconaut"

    module_function

    Result = Struct.new(:nodes_merged, :edges_merged, keyword_init: true) do
      def to_h = { nodes_merged: nodes_merged, edges_merged: edges_merged }
    end

    # Projette un payload `ScanResultV1` (Hash) dans AGE. Renvoie un
    # `Result` qui compte les MERGE effectifs (utile pour les specs).
    # Le caller fournit la connexion AR ouverte ; la transaction est
    # gérée à l'extérieur (pour permettre une projection en groupe).
    #
    # `metrics` accepte n'importe quoi qui répond à `observe(name, value, labels)`
    # (cf. Agent::TemplateExecutor::NullMetrics). Émet
    # `graph_lag_seconds` = now() - scan.observed_at à chaque commit.
    def call(payload:, connection: ActiveRecord::Base.connection, metrics: nil, clock: Time.method(:now))
      target_kind  = payload["target"]["kind"]
      target_value = payload["target"]["value"]
      findings     = Array(payload["findings"])

      stats = { nodes: 0, edges: 0 }

      ensure_age_loaded!(connection)

      # 1. Nœud racine selon target.kind
      case target_kind
      when "host"
        merge_host!(connection, target_value, stats)
      when "domain"
        merge_domain!(connection, target_value, stats)
      end

      # 2. Findings — chaque finding peut contribuer à plusieurs
      #    nœuds/arêtes. On reste défensif : un finding mal formé est
      #    sauté plutôt que de planter la projection entière.
      findings.each do |f|
        next unless f.is_a?(Hash)

        project_finding!(connection, target_kind, target_value, f, stats)
      end

      # Métrique graph_lag_seconds : délai entre `observed_at` du scan
      # et le commit de la projection. Cf. add-graph-retrieval §2.3.
      observe_lag(metrics, payload, clock)

      Result.new(nodes_merged: stats[:nodes], edges_merged: stats[:edges])
    end

    def observe_lag(metrics, payload, clock)
      return unless metrics
      observed_at = payload["observed_at"]
      return unless observed_at

      observed_time = Time.parse(observed_at)
      lag_seconds = (clock.call.utc - observed_time.utc).to_f
      metrics.observe(:graph_lag_seconds, lag_seconds, {})
    rescue ArgumentError, TypeError
      # observed_at mal formé : on ne casse pas la projection pour ça.
    end

    # ---------------------------------------------------------------------
    # MERGE primitifs
    # ---------------------------------------------------------------------

    def merge_host!(conn, host_id, stats)
      cypher(conn, <<~CYPHER, "(n agtype)")
        MERGE (n:Host {id: '#{escape(host_id)}'})
        RETURN n
      CYPHER
      stats[:nodes] += 1
    end

    def merge_domain!(conn, name, stats)
      cypher(conn, <<~CYPHER, "(n agtype)")
        MERGE (n:Domain {name: '#{escape(name)}'})
        RETURN n
      CYPHER
      stats[:nodes] += 1
    end

    def merge_service!(conn, host_id, port, protocol, stats)
      cypher(conn, <<~CYPHER, "(n agtype)")
        MERGE (h:Host {id: '#{escape(host_id)}'})
        MERGE (s:Service {host_id: '#{escape(host_id)}', port: #{port.to_i}, protocol: '#{escape(protocol)}'})
        MERGE (h)-[r:EXPOSES]->(s)
        RETURN s
      CYPHER
      stats[:nodes] += 1
      stats[:edges] += 1
    end

    def merge_certificate!(conn, host_id, sha256, stats)
      cypher(conn, <<~CYPHER, "(n agtype)")
        MERGE (h:Host {id: '#{escape(host_id)}'})
        MERGE (c:Certificate {sha256: '#{escape(sha256)}'})
        MERGE (h)-[r:PRESENTS]->(c)
        RETURN c
      CYPHER
      stats[:nodes] += 1
      stats[:edges] += 1
    end

    def merge_dns_resolution!(conn, domain, ip, stats)
      cypher(conn, <<~CYPHER, "(n agtype)")
        MERGE (d:Domain {name: '#{escape(domain)}'})
        MERGE (h:Host {id: '#{escape(ip)}'})
        MERGE (d)-[r:RESOLVES_TO]->(h)
        RETURN h
      CYPHER
      stats[:nodes] += 1
      stats[:edges] += 1
    end

    # ---------------------------------------------------------------------

    def project_finding!(conn, target_kind, target_value, finding, stats)
      port    = finding["port"]      || finding[:port]
      proto   = finding["protocol"]  || finding[:protocol] || "tcp"
      sha256  = finding["tls_cert_sha256"] || finding[:tls_cert_sha256]
      rtype   = finding["record_type"] || finding[:record_type]
      rvalue  = finding["value"]     || finding[:value]

      if port && target_kind == "host"
        merge_service!(conn, target_value, port, proto, stats)
      end
      if sha256 && target_kind == "host"
        merge_certificate!(conn, target_value, sha256, stats)
      end
      if %w[A AAAA].include?(rtype.to_s) && target_kind == "domain" && rvalue.to_s.length.positive?
        merge_dns_resolution!(conn, target_value, rvalue, stats)
      end
    end

    def ensure_age_loaded!(conn)
      conn.execute(%q[LOAD 'age'; SET search_path = ag_catalog, "$user", public;])
    end

    # cypher() retourne un PG::Result. La column_spec décrit les colonnes
    # retournées par AGE (toujours typées agtype).
    def cypher(conn, query, column_spec)
      conn.execute(<<~SQL)
        SELECT * FROM cypher('#{GRAPH_NAME}', $$
          #{query}
        $$) AS #{column_spec};
      SQL
    end

    # Cypher accepte les chaînes entre quotes simples ; on neutralise
    # les quotes simples dans la valeur. Les valeurs ingérées sont déjà
    # validées en amont (ScanResultV1 schema), donc on reste léger.
    def escape(value)
      value.to_s.gsub("'", "\\'")
    end
  end
end
