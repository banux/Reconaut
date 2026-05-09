# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Modèle de domaine fondamental de Reconaut : scope, hosts, services,
# scans. Cf. openspec/changes/init-reconaut-platform/specs/scanning/spec.md
# (Scope Declaration and Enforcement, Port and Service Fingerprinting,
# Retention).
#
# `services` est une hypertable TimescaleDB partitionnée par `scanned_at`
# (chunks journaliers) — politique de rétention 90 jours par défaut
# attachée à la fin de cette migration.
class CreateDomainModel < ActiveRecord::Migration[8.1]
  def up
    # ---- pgcrypto pour gen_random_uuid() ------------------------------------
    enable_extension "pgcrypto"

    # ---- scan_scope_entries -------------------------------------------------
    # L'opérateur déclare son scope ici. Trois formes : cidr, domain, host.
    # Une entrée n'est jamais supprimée : on pose `revoked_at` pour
    # garder la traçabilité (audit append-only).
    create_table :scan_scope_entries, id: :uuid do |t|
      t.string :kind, null: false # cidr / domain / host
      t.string :value, null: false, limit: 255
      t.text   :description
      t.string :created_by, null: false, limit: 128 # caller_id : key:<prefix>
      t.timestamp :created_at, null: false, default: -> { "now()" }
      t.timestamp :revoked_at
    end
    add_check_constraint :scan_scope_entries,
                         "kind IN ('cidr','domain','host')",
                         name: "scan_scope_entries_kind_check"
    add_index :scan_scope_entries, [:kind, :value],
              name: "idx_scope_kind_value"
    add_index :scan_scope_entries, :revoked_at,
              name: "idx_scope_active",
              where: "revoked_at IS NULL"

    # ---- hosts --------------------------------------------------------------
    # Un host = une cible identifiable par son IP et/ou son FQDN.
    # Les deux peuvent coexister (résolution DNS attache un FQDN à une IP).
    create_table :hosts, id: :uuid do |t|
      t.inet :ip
      t.string :fqdn, limit: 255
      t.timestamp :first_seen_at, null: false, default: -> { "now()" }
      t.timestamp :last_seen_at, null: false, default: -> { "now()" }
      t.timestamps null: false, default: -> { "now()" }
    end
    add_index :hosts, :ip, name: "idx_hosts_ip", where: "ip IS NOT NULL"
    add_index :hosts, :fqdn, name: "idx_hosts_fqdn", where: "fqdn IS NOT NULL"
    # Au moins un des deux doit être présent.
    add_check_constraint :hosts,
                         "ip IS NOT NULL OR fqdn IS NOT NULL",
                         name: "hosts_at_least_one_identifier"

    # ---- scans (table métier des jobs de scan) ------------------------------
    # Sert à `list_scans`/`get_scan_status` côté MCP. Persistance simple
    # — la file vivante reste good_jobs, cette table archive l'état.
    create_table :scans, id: :uuid do |t|
      t.string :scan_kind, null: false
      t.string :target_kind, null: false
      t.string :target_value, null: false, limit: 255
      t.string :idempotency_key, null: false, limit: 128
      t.string :status, null: false, default: "queued"
      t.timestamp :enqueued_at, null: false, default: -> { "now()" }
      t.timestamp :started_at
      t.timestamp :completed_at
      t.text :error
    end
    add_check_constraint :scans,
                         "status IN ('queued','running','done','failed')",
                         name: "scans_status_check"
    add_index :scans, :idempotency_key, unique: true, name: "uniq_scans_idempotency_key"
    add_index :scans, :enqueued_at, name: "idx_scans_enqueued_at"

    # ---- services -----------------------------------------------------------
    # Résultats de fingerprinting par (host, port, protocol, scanned_at).
    # Hypertable Timescale sur scanned_at — chunks journaliers, rétention 90j.
    create_table :services, id: false do |t|
      t.uuid       :id,         null: false, default: -> { "gen_random_uuid()" }
      t.uuid       :host_id,    null: false
      t.integer    :port,       null: false
      t.string     :protocol,   null: false, limit: 4 # tcp / udp
      t.string     :service_name, limit: 64
      t.text       :banner
      t.binary     :tls_cert_der
      t.string     :tls_cert_sha256, limit: 64
      t.timestamp  :tls_not_after
      t.integer    :duration_ms
      t.integer    :bytes_received
      t.string     :outcome,    null: false, limit: 16
      t.timestamp  :scanned_at, null: false
    end
    add_check_constraint :services,
                         "protocol IN ('tcp','udp')",
                         name: "services_protocol_check"
    add_check_constraint :services,
                         "outcome IN ('success','timeout','reset','tls_error','other')",
                         name: "services_outcome_check"
    add_check_constraint :services,
                         "port BETWEEN 0 AND 65535",
                         name: "services_port_range"

    # Clé primaire composée (id, scanned_at) — exigence des hypertables
    # Timescale : la PK doit inclure la colonne de partitionnement.
    execute <<~SQL
      ALTER TABLE services ADD PRIMARY KEY (id, scanned_at);
    SQL
    execute <<~SQL
      ALTER TABLE services
        ADD CONSTRAINT services_host_id_fkey
        FOREIGN KEY (host_id) REFERENCES hosts(id) ON DELETE CASCADE;
    SQL
    add_index :services, [:host_id, :port, :protocol], name: "idx_services_host_port_proto"
    add_index :services, :tls_cert_sha256,
              name: "idx_services_tls_sha256",
              where: "tls_cert_sha256 IS NOT NULL"

    # ---- TimescaleDB hypertable ---------------------------------------------
    # `services(scanned_at)` partitionné en chunks 1 jour. 90 jours
    # de rétention chaude par défaut (l'opérateur peut l'ajuster via
    # un futur outil MCP retention.set_hot_days).
    execute <<~SQL
      SELECT create_hypertable(
        'services',
        'scanned_at',
        chunk_time_interval => INTERVAL '1 day',
        if_not_exists       => TRUE,
        migrate_data        => TRUE
      );
    SQL
    execute <<~SQL
      SELECT add_retention_policy(
        'services',
        INTERVAL '90 days',
        if_not_exists => TRUE
      );
    SQL
  end

  def down
    # Retire la politique de rétention avant de drop l'hypertable.
    execute "SELECT remove_retention_policy('services', if_exists => TRUE);"

    drop_table :services if table_exists?(:services)
    drop_table :scans
    drop_table :hosts
    drop_table :scan_scope_entries

    # pgcrypto reste — peut être utilisée ailleurs.
  end
end
