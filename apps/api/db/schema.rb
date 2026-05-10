# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_10_000001) do
  create_schema "reconaut"

  # These are extensions that must be enabled in order to support this database
  enable_extension "ag_catalog.age"
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"
  enable_extension "public.timescaledb"
  enable_extension "public.vector"

# Could not dump table "AFFECTED_BY" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'end_id'


# Could not dump table "AutonomousSystem" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'id'


# Could not dump table "CPE" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'id'


# Could not dump table "Certificate" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'id'


# Could not dump table "Domain" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'id'


# Could not dump table "EXPOSES" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'end_id'


# Could not dump table "Host" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'id'


# Could not dump table "IN_AS" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'end_id'


# Could not dump table "IN_RANGE" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'end_id'


# Could not dump table "IPRange" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'id'


# Could not dump table "MATCHES_CPE" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'end_id'


# Could not dump table "OWNS" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'end_id'


# Could not dump table "Organization" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'id'


# Could not dump table "PARENT_OF" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'end_id'


# Could not dump table "PRESENTS" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'end_id'


# Could not dump table "RESOLVES_TO" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'end_id'


# Could not dump table "Service" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'id'


# Could not dump table "Vulnerability" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'id'


# Could not dump table "_ag_label_edge" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'end_id'


# Could not dump table "_ag_label_vertex" because of following StandardError
#   Unknown type 'ag_catalog.graphid' for column 'id'


  create_table "reconaut.api_keys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", precision: nil, default: -> { "now()" }, null: false
    t.string "prefix", limit: 8, null: false
    t.datetime "revoked_at", precision: nil
    t.text "scopes", default: [], null: false, array: true
    t.string "token_hash", limit: 64, null: false
    t.uuid "user_id", null: false
    t.index ["token_hash"], name: "idx_api_keys_token_hash_unique", unique: true
    t.index ["user_id"], name: "idx_api_keys_user_id"
  end

  create_table "reconaut.audit_log", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "caller_id", limit: 128, null: false
    t.integer "duration_ms"
    t.integer "nodes_touched"
    t.jsonb "params_normalized", default: {}, null: false
    t.datetime "recorded_at", precision: nil, default: -> { "now()" }, null: false
    t.string "status", limit: 32, null: false
    t.string "template_id", limit: 128
    t.index ["caller_id"], name: "idx_audit_log_caller_id"
    t.index ["recorded_at"], name: "idx_audit_log_recorded_at"
    t.index ["template_id"], name: "idx_audit_log_template_id", where: "(template_id IS NOT NULL)"
  end

# Could not dump table "embeddings" because of following StandardError
#   Unknown type 'public.vector(384)' for column 'vector'


  create_table "reconaut.hosts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "first_seen_at", precision: nil, default: -> { "now()" }, null: false
    t.string "fqdn", limit: 255
    t.inet "ip"
    t.datetime "last_seen_at", precision: nil, default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.index ["fqdn"], name: "idx_hosts_fqdn", where: "(fqdn IS NOT NULL)"
    t.index ["ip"], name: "idx_hosts_ip", where: "(ip IS NOT NULL)"
    t.check_constraint "ip IS NOT NULL OR fqdn IS NOT NULL", name: "hosts_at_least_one_identifier"
  end

  create_table "reconaut.scan_scope_entries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", precision: nil, default: -> { "now()" }, null: false
    t.string "created_by", limit: 128, null: false
    t.text "description"
    t.string "kind", null: false
    t.datetime "revoked_at", precision: nil
    t.string "value", limit: 255, null: false
    t.index ["kind", "value"], name: "idx_scope_kind_value"
    t.index ["revoked_at"], name: "idx_scope_active", where: "(revoked_at IS NULL)"
    t.check_constraint "kind::text = ANY (ARRAY['cidr'::character varying, 'domain'::character varying, 'host'::character varying]::text[])", name: "scan_scope_entries_kind_check"
  end

  create_table "reconaut.scans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "completed_at", precision: nil
    t.datetime "enqueued_at", precision: nil, default: -> { "now()" }, null: false
    t.text "error"
    t.string "idempotency_key", limit: 128, null: false
    t.string "scan_kind", null: false
    t.datetime "started_at", precision: nil
    t.string "status", default: "queued", null: false
    t.string "target_kind", null: false
    t.string "target_value", limit: 255, null: false
    t.index ["enqueued_at"], name: "idx_scans_enqueued_at"
    t.index ["idempotency_key"], name: "uniq_scans_idempotency_key", unique: true
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying, 'running'::character varying, 'done'::character varying, 'failed'::character varying]::text[])", name: "scans_status_check"
  end

  create_table "reconaut.services", primary_key: ["id", "scanned_at"], force: :cascade do |t|
    t.text "banner"
    t.integer "bytes_received"
    t.integer "duration_ms"
    t.uuid "host_id", null: false
    t.uuid "id", default: -> { "gen_random_uuid()" }, null: false
    t.string "outcome", limit: 16, null: false
    t.integer "port", null: false
    t.string "protocol", limit: 4, null: false
    t.datetime "scanned_at", precision: nil, null: false
    t.string "service_name", limit: 64
    t.binary "tls_cert_der"
    t.string "tls_cert_sha256", limit: 64
    t.datetime "tls_not_after", precision: nil
    t.index ["host_id", "port", "protocol"], name: "idx_services_host_port_proto"
    t.index ["scanned_at"], name: "services_scanned_at_idx", order: :desc
    t.index ["tls_cert_sha256"], name: "idx_services_tls_sha256", where: "(tls_cert_sha256 IS NOT NULL)"
    t.check_constraint "outcome::text = ANY (ARRAY['success'::character varying, 'timeout'::character varying, 'reset'::character varying, 'tls_error'::character varying, 'other'::character varying]::text[])", name: "services_outcome_check"
    t.check_constraint "port >= 0 AND port <= 65535", name: "services_port_range"
    t.check_constraint "protocol::text = ANY (ARRAY['tcp'::character varying, 'udp'::character varying]::text[])", name: "services_protocol_check"
  end

  create_table "reconaut.users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", precision: nil, default: -> { "now()" }, null: false
    t.datetime "disabled_at", precision: nil
    t.citext "email", null: false
    t.string "password_hash", null: false
    t.index ["email"], name: "idx_users_email_unique", unique: true
  end

  add_foreign_key "reconaut.api_keys", "reconaut.users", on_delete: :cascade
  add_foreign_key "reconaut.embeddings", "reconaut.hosts", on_delete: :cascade
  add_foreign_key "reconaut.services", "reconaut.hosts", name: "services_host_id_fkey", on_delete: :cascade

end
