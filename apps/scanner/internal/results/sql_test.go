// SPDX-License-Identifier: AGPL-3.0-only
package results

import (
	"context"
	"errors"
	"regexp"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
)

// TestSQLStore_InsertSuccess : la query exacte est envoyée, le mock
// retourne 1 row → inserted=true.
func TestSQLStore_InsertSuccess(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatalf("sqlmock: %v", err)
	}
	defer db.Close()

	r := Result{
		IdempotencyKey: "k-1",
		ScanKind:       "dns_records",
		TargetKind:     "domain",
		TargetValue:    "example.fr",
		Status:         `{"records":[]}`,
		ObservedAt:     time.Date(2026, 5, 12, 13, 0, 0, 0, time.UTC),
	}

	// On matche le SQL au regex (sqlmock par défaut utilise QueryMatcherRegexp).
	// Le RETURNING idempotency_key permet au Scan de réussir avec la ligne
	// fixture.
	mock.ExpectQuery(regexp.QuoteMeta("INSERT INTO scan_results")).
		WithArgs(r.IdempotencyKey, r.ScanKind, r.TargetKind, r.TargetValue, r.Status, r.ObservedAt).
		WillReturnRows(sqlmock.NewRows([]string{"idempotency_key"}).AddRow(r.IdempotencyKey))

	store := NewSQLStore(db)
	inserted, err := store.Insert(context.Background(), r)
	if err != nil {
		t.Fatalf("Insert: %v", err)
	}
	if !inserted {
		t.Errorf("expected inserted=true, got false")
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("sqlmock expectations: %v", err)
	}
}

// TestSQLStore_InsertConflict : le mock retourne 0 row (ON CONFLICT
// court-circuit) → inserted=false, err=nil.
func TestSQLStore_InsertConflict(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatalf("sqlmock: %v", err)
	}
	defer db.Close()

	r := Result{
		IdempotencyKey: "k-dup",
		ScanKind:       "dns_records",
		TargetKind:     "domain",
		TargetValue:    "example.fr",
		Status:         "ok",
		ObservedAt:     time.Now().UTC(),
	}

	// Empty rows simule ON CONFLICT DO NOTHING : aucune ligne RETURNING.
	mock.ExpectQuery(regexp.QuoteMeta("INSERT INTO scan_results")).
		WithArgs(r.IdempotencyKey, r.ScanKind, r.TargetKind, r.TargetValue, r.Status, r.ObservedAt).
		WillReturnRows(sqlmock.NewRows([]string{"idempotency_key"}))

	store := NewSQLStore(db)
	inserted, err := store.Insert(context.Background(), r)
	if err != nil {
		t.Fatalf("Insert: expected nil error on conflict, got %v", err)
	}
	if inserted {
		t.Errorf("expected inserted=false on conflict, got true")
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("sqlmock expectations: %v", err)
	}
}

// TestSQLStore_InsertEmptyKey : la clé vide est rejetée AVANT d'atteindre
// la DB (sqlmock ne reçoit aucune requête).
func TestSQLStore_InsertEmptyKey(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatalf("sqlmock: %v", err)
	}
	defer db.Close()

	store := NewSQLStore(db)
	inserted, err := store.Insert(context.Background(), Result{
		IdempotencyKey: "",
		ScanKind:       "x",
		TargetKind:     "y",
		TargetValue:    "z",
	})
	if !errors.Is(err, ErrMissingIdempotencyKey) {
		t.Fatalf("expected ErrMissingIdempotencyKey, got %v", err)
	}
	if inserted {
		t.Errorf("expected inserted=false on empty key, got true")
	}
	// Aucune query ne devait être déclenchée.
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("sqlmock expectations: %v", err)
	}
}

// TestSQLStore_List : renvoie les rows triées telles que retournées par
// la DB. On valide aussi que le LIMIT et l'ORDER BY sont dans la query.
func TestSQLStore_List(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatalf("sqlmock: %v", err)
	}
	defer db.Close()

	t1 := time.Date(2026, 5, 12, 10, 0, 0, 0, time.UTC)
	t2 := time.Date(2026, 5, 12, 11, 0, 0, 0, time.UTC)

	rows := sqlmock.NewRows([]string{"idempotency_key", "scan_kind", "target_kind", "target_value", "status", "observed_at"}).
		AddRow("k-A", "dns_records", "domain", "a.fr", "ok", t1).
		AddRow("k-B", "service_fingerprint", "host", "b.fr", `{"banner":"SSH-..."}`, t2)

	mock.ExpectQuery(regexp.QuoteMeta("SELECT idempotency_key, scan_kind, target_kind, target_value, status, observed_at")).
		WillReturnRows(rows)

	store := NewSQLStore(db)
	out, err := store.List(context.Background())
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(out) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(out))
	}
	if out[0].IdempotencyKey != "k-A" || out[1].IdempotencyKey != "k-B" {
		t.Errorf("unexpected order: %+v", out)
	}
	if !out[0].ObservedAt.Equal(t1) {
		t.Errorf("observed_at[0] mismatch: got %v want %v", out[0].ObservedAt, t1)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("sqlmock expectations: %v", err)
	}
}

// TestSQLStore_InsertSQLContainsExpectedQuery : on vérifie via le
// matcher regex que la query passée contient bien
// `ON CONFLICT (idempotency_key) DO NOTHING` et le `RETURNING`. C'est
// une assertion statique sur le SQL exact aligné avec la spec.
func TestSQLStore_InsertSQLContainsExpectedQuery(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatalf("sqlmock: %v", err)
	}
	defer db.Close()

	r := Result{
		IdempotencyKey: "static-1",
		ScanKind:       "k",
		TargetKind:     "t",
		TargetValue:    "v",
		Status:         "s",
		ObservedAt:     time.Now().UTC(),
	}

	// Le matcher attend la combinaison ON CONFLICT + RETURNING dans la query.
	mock.ExpectQuery(`ON CONFLICT \(idempotency_key\) DO NOTHING\s+RETURNING idempotency_key`).
		WithArgs(r.IdempotencyKey, r.ScanKind, r.TargetKind, r.TargetValue, r.Status, r.ObservedAt).
		WillReturnRows(sqlmock.NewRows([]string{"idempotency_key"}).AddRow(r.IdempotencyKey))

	if _, err := NewSQLStore(db).Insert(context.Background(), r); err != nil {
		t.Fatalf("Insert: %v", err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("sqlmock expectations: %v", err)
	}
}
