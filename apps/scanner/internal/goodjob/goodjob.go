// Package goodjob implements the Go-side consumer of the GoodJob queue
// shared with the Rails monolith.
//
// Spec source:
//
//	openspec/changes/add-tech-stack/specs/architecture/spec.md
//	  Requirement: Rails ↔ Go Communication via GoodJob
//	  Requirement: Horizontal Distribution of Scan Workers
//	openspec/changes/add-tech-stack/tasks.md sections 3.2 and 5.1
//
// The Rails app enqueues `ScanJob.perform_later(payload)` which writes a
// row into the `good_jobs` table (GoodJob 4.x adapter for ActiveJob).
// The Go workers claim rows directly via:
//
//	SELECT id, active_job_id, queue_name, serialized_params, scheduled_at
//	FROM good_jobs
//	WHERE finished_at IS NULL
//	  AND queue_name = $1
//	  AND (scheduled_at IS NULL OR scheduled_at <= NOW())
//	ORDER BY priority NULLS LAST, scheduled_at NULLS FIRST, created_at
//	FOR UPDATE SKIP LOCKED
//	LIMIT 1
//
// Once a row is claimed, the worker:
//   - parses the payload from `serialized_params -> arguments[0]`
//     (ActiveJob serialization wraps the perform_later args in an array),
//   - validates the payload against ScanJobV1 (cf. internal/jobschema),
//   - runs the handler under SafeRun (cf. internal/worker.SafeRun),
//   - on success: UPDATE good_jobs SET performed_at = NOW(),
//     finished_at = NOW() WHERE id = $1
//   - on failure: UPDATE good_jobs SET error = $2, performed_at = NOW(),
//     finished_at = NOW() WHERE id = $1 (no retry: GoodJob server-side
//     retry policy is configured Rails-side; the Go worker just records
//     the failure so the Rails dashboard can display it).
//
// No external broker (Redis, RabbitMQ, NATS, Kafka) is involved — the
// queue lives in the same Postgres cluster as the rest of the OLTP data.
package goodjob

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Job mirrors the subset of `good_jobs` columns the worker cares about.
// The full row has many more columns (concurrency_key, scheduled_at,
// finished_at, error, etc.) — the worker only needs to read the params
// and update finished_at / error after handling.
type Job struct {
	// ID is the GoodJob row primary key (UUID).
	ID string
	// ActiveJobID is the ActiveJob UUID (`active_job_id` column).
	// Useful for correlation with Rails logs.
	ActiveJobID string
	// QueueName is the ActiveJob queue (e.g. "scan").
	QueueName string
	// Params is the parsed first argument of the ActiveJob payload (i.e.
	// the Hash passed to `ScanJob.perform_later(payload)`).
	Params map[string]any
	// EnqueuedAt is when the row was created.
	EnqueuedAt time.Time
}

// Store is the abstraction the worker loop depends on. The production
// implementation (NewSQLStore) talks to Postgres via `database/sql`
// using SELECT ... FOR UPDATE SKIP LOCKED. Tests use the InMemoryStore.
//
// Claim returns (nil, ErrNoJob) when the queue is empty; this is a
// normal condition the loop translates into a backoff sleep, not an
// error.
type Store interface {
	Claim(ctx context.Context, queue string) (*Job, error)
	Finish(ctx context.Context, jobID string) error
	Fail(ctx context.Context, jobID string, reason string) error
}

// ErrNoJob signals an empty queue. Callers should NOT treat this as a
// hard error — it just means there's nothing to do right now.
var ErrNoJob = errors.New("goodjob: no job available")

// ParseSerializedParams extracts the first positional argument from the
// ActiveJob `serialized_params` JSON blob. ActiveJob serializes a call
// to `ScanJob.perform_later(payload)` as something like:
//
//	{
//	  "job_class": "ScanJob",
//	  "queue_name": "scan",
//	  "arguments": [ <payload as JSON-friendly Hash> ],
//	  ...
//	}
//
// We pull `arguments[0]` and decode it into a generic map. The schema
// validation (cf. internal/jobschema) is the next step; this function
// only does the structural extraction.
//
// Returns an error if the JSON is malformed, if `arguments` is missing
// or empty, or if the first argument isn't a JSON object.
func ParseSerializedParams(raw []byte) (map[string]any, error) {
	if len(raw) == 0 {
		return nil, errors.New("goodjob: empty serialized_params")
	}
	var envelope struct {
		Arguments []json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, fmt.Errorf("goodjob: serialized_params is not valid JSON: %w", err)
	}
	if len(envelope.Arguments) == 0 {
		return nil, errors.New("goodjob: serialized_params has no arguments")
	}
	var payload map[string]any
	if err := json.Unmarshal(envelope.Arguments[0], &payload); err != nil {
		return nil, fmt.Errorf("goodjob: first argument is not a JSON object: %w", err)
	}
	return payload, nil
}

// EncodeSerializedParams is the symmetric helper used by tests and the
// in-memory store: it builds a minimal ActiveJob-shaped envelope around
// a payload Hash. The production path doesn't use this — Rails writes
// the row.
func EncodeSerializedParams(payload map[string]any) ([]byte, error) {
	envelope := map[string]any{
		"job_class":  "ScanJob",
		"queue_name": "scan",
		"arguments":  []any{payload},
	}
	return json.Marshal(envelope)
}
