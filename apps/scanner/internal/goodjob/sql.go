// SPDX-License-Identifier: AGPL-3.0-only
// Package goodjob — SQL-backed Store implementation.
//
// Uses `database/sql` so any driver (lib/pq, pgx via stdlib mode) works.
// The actual driver registration is the binary's responsibility.

package goodjob

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// claimSQL is the read-and-lock query. Order:
//   - priority lower number first (NULL last so unprioritized jobs go to the back)
//   - scheduled_at first if present and elapsed (FIFO of the schedule)
//   - then created_at FIFO
//
// We restrict to the queue we want and skip rows already locked by a
// concurrent worker.
const claimSQL = `
SELECT
    id::text,
    COALESCE(active_job_id::text, ''),
    queue_name,
    serialized_params,
    created_at
FROM good_jobs
WHERE finished_at IS NULL
  AND queue_name = $1
  AND (scheduled_at IS NULL OR scheduled_at <= NOW())
ORDER BY priority ASC NULLS LAST,
         scheduled_at ASC NULLS FIRST,
         created_at ASC
FOR UPDATE SKIP LOCKED
LIMIT 1
`

const finishSQL = `
UPDATE good_jobs
SET performed_at = COALESCE(performed_at, NOW()),
    finished_at = NOW()
WHERE id = $1
  AND finished_at IS NULL
`

const failSQL = `
UPDATE good_jobs
SET performed_at = COALESCE(performed_at, NOW()),
    finished_at = NOW(),
    error = $2
WHERE id = $1
  AND finished_at IS NULL
`

// Beginner is the minimal subset of *sql.DB that we need to start a
// transaction. The interface lets tests pass a wrapper.
type Beginner interface {
	BeginTx(ctx context.Context, opts *sql.TxOptions) (*sql.Tx, error)
}

// SQLStore is the production Store. It runs Claim inside a transaction
// (mandatory for FOR UPDATE SKIP LOCKED to hold the row lock until
// Finish/Fail commits).
//
// Important: Claim does NOT commit. The caller MUST call either Finish
// or Fail with the same Store instance to commit the transaction. To
// stay consistent with the Store interface (which is stateless), each
// SQLStore tracks the in-flight transaction per claimed job ID.
//
// This does mean SQLStore is *not* safe for concurrent claim of multiple
// jobs from the same Store value — the worker creates one SQLStore per
// goroutine claiming jobs.
type SQLStore struct {
	db Beginner
	// active holds the open Tx for the most recently claimed job. It's
	// keyed by job ID to support pipelined claim/finish in tests; in
	// production the worker handles one job at a time per goroutine.
	active map[string]*sql.Tx
}

// NewSQLStore wires a Store to an existing database handle. The caller
// owns the *sql.DB lifecycle.
func NewSQLStore(db Beginner) *SQLStore {
	return &SQLStore{db: db, active: make(map[string]*sql.Tx)}
}

// Claim acquires the next job for the given queue and locks it. The
// caller must complete the cycle by calling Finish or Fail with the
// returned job's ID.
func (s *SQLStore) Claim(ctx context.Context, queue string) (*Job, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return nil, fmt.Errorf("goodjob: begin tx: %w", err)
	}

	row := tx.QueryRowContext(ctx, claimSQL, queue)
	var (
		id          string
		activeJobID string
		queueName   string
		raw         []byte
		createdAt   time.Time
	)
	err = row.Scan(&id, &activeJobID, &queueName, &raw, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		_ = tx.Rollback()
		return nil, ErrNoJob
	}
	if err != nil {
		_ = tx.Rollback()
		return nil, fmt.Errorf("goodjob: scan claim: %w", err)
	}

	params, err := ParseSerializedParams(raw)
	if err != nil {
		// Malformed payload — close the row out as failed rather than
		// leave it locked forever. We commit the failure update and
		// surface the parse error.
		_, fErr := tx.ExecContext(ctx, failSQL, id, "malformed serialized_params: "+err.Error())
		if fErr != nil {
			_ = tx.Rollback()
			return nil, fmt.Errorf("goodjob: parse + fail: %w (parse) / %v (fail)", err, fErr)
		}
		if cErr := tx.Commit(); cErr != nil {
			return nil, fmt.Errorf("goodjob: parse + commit fail: %w (parse) / %v (commit)", err, cErr)
		}
		return nil, fmt.Errorf("goodjob: %w", err)
	}

	s.active[id] = tx
	return &Job{
		ID:          id,
		ActiveJobID: activeJobID,
		QueueName:   queueName,
		Params:      params,
		EnqueuedAt:  createdAt,
	}, nil
}

// Finish marks the job as completed and commits the row lock.
func (s *SQLStore) Finish(ctx context.Context, jobID string) error {
	tx, ok := s.active[jobID]
	if !ok {
		return fmt.Errorf("goodjob: no active tx for job %s", jobID)
	}
	delete(s.active, jobID)

	if _, err := tx.ExecContext(ctx, finishSQL, jobID); err != nil {
		_ = tx.Rollback()
		return fmt.Errorf("goodjob: exec finish: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("goodjob: commit finish: %w", err)
	}
	return nil
}

// Fail marks the job as failed (records the error message) and commits.
// The job will appear in the GoodJob "failed" view in the Rails
// dashboard.
func (s *SQLStore) Fail(ctx context.Context, jobID, reason string) error {
	tx, ok := s.active[jobID]
	if !ok {
		return fmt.Errorf("goodjob: no active tx for job %s", jobID)
	}
	delete(s.active, jobID)

	if _, err := tx.ExecContext(ctx, failSQL, jobID, reason); err != nil {
		_ = tx.Rollback()
		return fmt.Errorf("goodjob: exec fail: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("goodjob: commit fail: %w", err)
	}
	return nil
}
