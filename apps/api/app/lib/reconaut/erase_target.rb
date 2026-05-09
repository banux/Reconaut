# frozen_string_literal: true

module Reconaut
  # EraseTarget : efface en transaction Postgres toutes les données
  # liées à un identifiant (host_id, fqdn, IP, domain).
  #
  # Couvre :
  #   - lignes scalaires : `hosts` (cascade sur services via FK), `scans`
  #     dont le target matche.
  #   - nœuds/arêtes du graphe AGE : Host{id=...}, Domain{name=...},
  #     Service{host_id=...}, Certificate liés via PRESENTS, etc.
  #
  # Atomique : tout commit ou tout rollback. Aucun framework RGPD —
  # c'est un outil **opérationnel** (hygiène de la base de connaissance,
  # nettoyage d'un actif retiré du scope, purge d'une entrée erronée).
  # Cf. openspec/changes/init-reconaut-platform/tasks.md §6.2 (reformulé
  # par drop-gdpr-framing) et add-graph-retrieval §6.1/§6.2.
  module EraseTarget
    GRAPH_NAME = "reconaut"

    Result = Struct.new(:hosts_deleted, :services_deleted, :scans_deleted,
                        :graph_nodes_deleted, keyword_init: true) do
      def to_h
        {
          hosts_deleted: hosts_deleted,
          services_deleted: services_deleted,
          scans_deleted: scans_deleted,
          graph_nodes_deleted: graph_nodes_deleted
        }
      end
    end

    module_function

    # Efface tout ce qui matche `target` (string : un host_id UUID, un
    # FQDN, une IP, ou un domaine). Le service essaye d'abord par
    # host_id (UUID strict), sinon il match sur FQDN/IP littéral pour
    # les hôtes scalaires et name=domain pour le graphe.
    #
    # `audit_recorder` (optionnel) reçoit une ligne avec
    # `target_hash=<sha256(target)>` et le compte d'objets supprimés.
    def call(target:, connection: ActiveRecord::Base.connection, audit_recorder: nil, caller_id: "anonymous")
      raise ArgumentError, "target required" if target.to_s.strip.empty?

      stats = { hosts: 0, services: 0, scans: 0, graph_nodes: 0 }

      connection.transaction do
        ensure_age_loaded!(connection)

        stats[:hosts]    = delete_hosts!(connection, target)
        stats[:services] = service_count_for_audit(stats[:hosts])
        stats[:scans]    = delete_scans!(connection, target)
        stats[:graph_nodes] = delete_graph_nodes!(connection, target)
      end

      record_audit(audit_recorder, target, stats, caller_id, outcome: :success)

      Result.new(
        hosts_deleted:        stats[:hosts],
        services_deleted:     stats[:services],
        scans_deleted:        stats[:scans],
        graph_nodes_deleted:  stats[:graph_nodes]
      )
    rescue StandardError => e
      record_audit(audit_recorder, target, stats, caller_id,
                   outcome: :failure, error: e.message)
      raise
    end

    # ---------------------------------------------------------------------

    def delete_hosts!(conn, target)
      # Match par id (uuid string), fqdn ou ip. PG accepte la string
      # même quand le cast d'inet échouerait — on les compare textuellement.
      uuid_match = target.match?(/\A[0-9a-f-]{36}\z/i) ? target : nil
      conditions = []
      values     = []
      if uuid_match
        conditions << "id = $#{values.size + 1}::uuid"
        values << uuid_match
      end
      conditions << "fqdn = $#{values.size + 1}"
      values << target
      conditions << "host(ip) = $#{values.size + 1}"
      values << target
      sql = "DELETE FROM hosts WHERE #{conditions.join(' OR ')} RETURNING id"
      result = conn.exec_query(sql, "hosts.delete", values)
      result.rows.size
    end

    def service_count_for_audit(_hosts_deleted)
      # FK ON DELETE CASCADE supprime les services rattachés ; on n'a
      # pas un compte exact ici sans count_before. Renvoie 0 par défaut
      # pour ne pas mentir — le caller verra `hosts_deleted` qui est la
      # mesure utile.
      0
    end

    def delete_scans!(conn, target)
      sql = <<~SQL
        DELETE FROM scans
         WHERE target_value = $1
            OR idempotency_key LIKE '%' || $1 || '%'
        RETURNING id
      SQL
      result = conn.exec_query(sql, "scans.delete", [target])
      result.rows.size
    end

    def delete_graph_nodes!(conn, target)
      escaped = target.gsub("'", "\\'")
      result = conn.execute(<<~SQL)
        SELECT * FROM cypher('#{GRAPH_NAME}', $$
          MATCH (n)
          WHERE n.id = '#{escaped}'
             OR n.name = '#{escaped}'
             OR n.host_id = '#{escaped}'
          DETACH DELETE n
          RETURN count(*) AS c
        $$) AS (c agtype);
      SQL
      row = result.to_a.first
      return 0 unless row

      row["c"].to_i
    end

    def ensure_age_loaded!(conn)
      conn.execute(%q[LOAD 'age'; SET search_path = ag_catalog, "$user", public;])
    end

    def record_audit(recorder, target, stats, caller_id, outcome:, error: nil)
      return unless recorder

      target_hash = Digest::SHA256.hexdigest(target.to_s)
      recorder.record(
        status:           outcome == :success ? :success : :param_invalid,
        template_id:      "erase_target",
        params_normalized: {
          action:              "erase",
          target_hash:         target_hash,
          hosts_deleted:       stats[:hosts],
          scans_deleted:       stats[:scans],
          graph_nodes_deleted: stats[:graph_nodes],
          error:               error
        }.compact,
        caller_id:    caller_id,
        duration_ms:  0,
        nodes_touched: stats[:graph_nodes].to_i + stats[:hosts].to_i
      )
    rescue StandardError
      # L'audit ne doit JAMAIS faire échouer l'erase
    end
  end
end
