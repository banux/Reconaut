// SPDX-License-Identifier: AGPL-3.0-only
// Package results — SQL-backed Store implementation.
//
// Contrat aligné sur l'in-memory variant :
//
//   - Insert : INSERT ... ON CONFLICT (idempotency_key) DO NOTHING
//     RETURNING idempotency_key. Le RETURNING permet de distinguer
//     (a) row insérée → renvoie la clé → inserted=true ;
//     (b) conflit → 0 rows → sql.ErrNoRows → inserted=false, err=nil ;
//     (c) autre erreur DB → remontée telle quelle.
//   - List : SELECT triée par observed_at ASC, plafonnée à 1000 lignes
//     (suffisant pour les tests et le dev local ; en prod les requêtes
//     se font via Rails / MCP avec filtres explicites).
//   - IdempotencyKey vide → rejet AVANT de toucher la DB
//     (ErrMissingIdempotencyKey).
//
// Source de vérité :
//
//	openspec/changes/add-scanner-pgx-driver/specs/scanning/spec.md
//	  -> Requirement: Postgres-Backed Scanner Stores

package results

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

const insertSQL = `
INSERT INTO scan_results
    (idempotency_key, scan_kind, target_kind, target_value, status, observed_at)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING idempotency_key
`

const listSQL = `
SELECT idempotency_key, scan_kind, target_kind, target_value, status, observed_at
FROM scan_results
ORDER BY observed_at ASC
LIMIT 1000
`

// SQLStore persiste les Result dans la table scan_results via le pilote
// database/sql (le binaire enregistre pgx via blank import dans
// internal/runtime).
type SQLStore struct {
	db *sql.DB
}

// NewSQLStore wire le store à un handle *sql.DB déjà ouvert. Le caller
// possède le lifecycle de db (Close se fait au niveau runtime).
func NewSQLStore(db *sql.DB) *SQLStore {
	return &SQLStore{db: db}
}

// Insert applique INSERT ... ON CONFLICT DO NOTHING. Renvoie
// (true, nil) si la ligne a été insérée, (false, nil) si la clé
// existait déjà (idempotence). Une clé vide est rejetée localement.
func (s *SQLStore) Insert(ctx context.Context, r Result) (bool, error) {
	if r.IdempotencyKey == "" {
		return false, ErrMissingIdempotencyKey
	}

	var key string
	err := s.db.QueryRowContext(ctx, insertSQL,
		r.IdempotencyKey,
		r.ScanKind,
		r.TargetKind,
		r.TargetValue,
		r.Status,
		r.ObservedAt,
	).Scan(&key)

	if errors.Is(err, sql.ErrNoRows) {
		// ON CONFLICT a court-circuité — pas d'erreur, just idempotence.
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("results: insert: %w", err)
	}
	return true, nil
}

// List retourne les résultats triés par observed_at ascendant. Plafond
// dur à 1000 pour rester safe en dev — les usages prod passeront par
// Rails / MCP avec filtres explicites.
func (s *SQLStore) List(ctx context.Context) ([]Result, error) {
	rows, err := s.db.QueryContext(ctx, listSQL)
	if err != nil {
		return nil, fmt.Errorf("results: list: %w", err)
	}
	defer rows.Close()

	out := make([]Result, 0, 32)
	for rows.Next() {
		var r Result
		if err := rows.Scan(&r.IdempotencyKey, &r.ScanKind, &r.TargetKind, &r.TargetValue, &r.Status, &r.ObservedAt); err != nil {
			return nil, fmt.Errorf("results: scan: %w", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("results: rows: %w", err)
	}
	return out, nil
}
