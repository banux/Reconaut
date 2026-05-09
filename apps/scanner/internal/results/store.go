// SPDX-License-Identifier: AGPL-3.0-only
// Package results stores the outcomes produced by the scan worker
// after handling a job.
//
// Spec source:
//
//	openspec/changes/add-tech-stack/tasks.md §5.1 :
//	  "ecrit le resultat en table metier puis update la ligne good_jobs
//	   avec finished_at = NOW(). Idempotence : table de deduplication
//	   par idempotency_key ou INSERT ... ON CONFLICT DO NOTHING cote
//	   resultats."
//
// The Store interface wraps "insert if new" semantics. The production
// implementation will be backed by Postgres (an `INSERT ... ON CONFLICT
// DO NOTHING` against a table keyed by idempotency_key once the
// init-reconaut-platform §2.1 migrations land). The in-memory variant
// here is enough to drive the worker loop in tests and to back the
// dev-local dry run that ships with the bootstrap binary.
package results

import (
	"context"
	"sync"
	"time"
)

// Result captures the outcome of a single scan job. Minimal in v1: the
// scan kind, target, idempotency key (deduplication discriminant), the
// time we observed the work as "completed", and a status string.
//
// When the real scan engine lands the Result struct will grow ports,
// services, certificates, banner snippets, etc. — for now the no-op
// placeholder records "ok" or "skipped (duplicate)" so the worker loop
// has something to assert against in integration tests.
type Result struct {
	IdempotencyKey string
	ScanKind       string
	TargetKind     string
	TargetValue    string
	Status         string
	ObservedAt     time.Time
}

// Store records scan results with deduplication by IdempotencyKey.
//
// Insert returns (true, nil) when the row was inserted, (false, nil)
// when a row with the same IdempotencyKey already existed (i.e. the
// caller was a duplicate). Any other failure surfaces as a non-nil
// error.
type Store interface {
	Insert(ctx context.Context, r Result) (inserted bool, err error)
	List(ctx context.Context) ([]Result, error)
}

// InMemoryStore is the test/dev implementation. Thread-safe for
// concurrent Insert calls coming from multiple worker goroutines.
type InMemoryStore struct {
	mu      sync.Mutex
	byKey   map[string]Result
	ordered []Result
}

// NewInMemoryStore returns an empty in-memory store.
func NewInMemoryStore() *InMemoryStore {
	return &InMemoryStore{byKey: make(map[string]Result)}
}

// Insert applies the "INSERT ... ON CONFLICT DO NOTHING" contract. If
// IdempotencyKey is empty the insert is rejected — every result MUST
// carry a deduplication discriminant.
func (s *InMemoryStore) Insert(_ context.Context, r Result) (bool, error) {
	if r.IdempotencyKey == "" {
		return false, ErrMissingIdempotencyKey
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.byKey[r.IdempotencyKey]; exists {
		return false, nil
	}
	s.byKey[r.IdempotencyKey] = r
	s.ordered = append(s.ordered, r)
	return true, nil
}

// List returns the inserted results in arrival order. Useful for tests
// that want to assert on what got persisted.
func (s *InMemoryStore) List(_ context.Context) ([]Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Result, len(s.ordered))
	copy(out, s.ordered)
	return out, nil
}

// Count returns how many unique results have been inserted.
func (s *InMemoryStore) Count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.byKey)
}

// ErrMissingIdempotencyKey is returned when Insert is called with an
// empty IdempotencyKey — the contract REQUIRES one.
var ErrMissingIdempotencyKey = errMissingKey{}

type errMissingKey struct{}

func (errMissingKey) Error() string { return "results: missing idempotency_key" }
