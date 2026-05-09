# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Crée la table `audit_log` append-only.
#
# Cf. openspec/changes/init-reconaut-platform/tasks.md §6.3 (reformulé
# par drop-gdpr-framing) — cadrage opérationnel : forensique, debug,
# accountability vis-à-vis de l'opérateur lui-même. Pas un registre
# de traitements RGPD.
#
# Append-only via TRIGGER : tout UPDATE/DELETE direct lève une
# EXCEPTION Postgres. Les tentatives sont elles-mêmes journalisées
# côté Postgres logs (le RAISE EXCEPTION apparaît dans le journal).
class CreateAuditLog < ActiveRecord::Migration[8.1]
  def up
    create_table :audit_log, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string  :status,            null: false, limit: 32
      t.string  :template_id,       limit: 128
      t.jsonb   :params_normalized, null: false, default: {}
      t.string  :caller_id,         null: false, limit: 128
      t.integer :duration_ms
      t.integer :nodes_touched
      t.timestamp :recorded_at, null: false, default: -> { "now()" }
    end

    add_index :audit_log, :recorded_at, name: "idx_audit_log_recorded_at"
    add_index :audit_log, :caller_id, name: "idx_audit_log_caller_id"
    add_index :audit_log, :template_id,
              name: "idx_audit_log_template_id",
              where: "template_id IS NOT NULL"

    # TRIGGER append-only. Toute tentative UPDATE/DELETE échoue avec
    # un code d'erreur explicite. Le rôle propriétaire de la fonction
    # ne peut pas être bypassed — même par un superuser, l'exception
    # remonte à l'application.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION audit_log_reject_mutation()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'audit_log is append-only ; UPDATE/DELETE rejected'
          USING ERRCODE = 'insufficient_privilege';
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER audit_log_no_update
        BEFORE UPDATE ON audit_log
        FOR EACH ROW
        EXECUTE FUNCTION audit_log_reject_mutation();
    SQL

    execute <<~SQL
      CREATE TRIGGER audit_log_no_delete
        BEFORE DELETE ON audit_log
        FOR EACH ROW
        EXECUTE FUNCTION audit_log_reject_mutation();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS audit_log_no_update ON audit_log;"
    execute "DROP TRIGGER IF EXISTS audit_log_no_delete ON audit_log;"
    execute "DROP FUNCTION IF EXISTS audit_log_reject_mutation();"
    drop_table :audit_log
  end
end
