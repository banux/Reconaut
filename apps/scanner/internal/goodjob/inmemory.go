// SPDX-License-Identifier: AGPL-3.0-only
// Package goodjob — in-memory Store for tests and dev local stub.

package goodjob

import (
	"context"
	"sync"
	"time"
)

// InMemoryStore mimics the Postgres-backed Store without touching a DB.
// It supports concurrent Claim from multiple goroutines using a mutex.
// Useful for unit tests of the worker loop (panic handling, dispatch,
// idempotence) without spinning up a Postgres container.
type InMemoryStore struct {
	mu   sync.Mutex
	jobs []inMemJob
	// claimed tracks jobs locked by a Claim that hasn't been
	// Finish/Fail'd yet, mirroring the FOR UPDATE SKIP LOCKED behaviour.
	claimed map[string]bool
	// finished records terminal state for assertions.
	finished map[string]string // jobID -> "success" or error reason
}

type inMemJob struct {
	id          string
	activeJobID string
	queueName   string
	params      map[string]any
	enqueuedAt  time.Time
}

// NewInMemoryStore returns an empty store.
func NewInMemoryStore() *InMemoryStore {
	return &InMemoryStore{
		claimed:  make(map[string]bool),
		finished: make(map[string]string),
	}
}

// Enqueue is the test counterpart of Rails' `ScanJob.perform_later` —
// it appends a job to the in-memory queue. Returns the assigned ID.
func (s *InMemoryStore) Enqueue(jobID, activeJobID, queueName string, payload map[string]any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.jobs = append(s.jobs, inMemJob{
		id:          jobID,
		activeJobID: activeJobID,
		queueName:   queueName,
		params:      payload,
		enqueuedAt:  time.Now(),
	})
}

// Claim removes and returns the next available job for the queue. If a
// job is already claimed, it skips it (FOR UPDATE SKIP LOCKED
// equivalent).
func (s *InMemoryStore) Claim(_ context.Context, queue string) (*Job, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, j := range s.jobs {
		if j.queueName != queue || s.claimed[j.id] {
			continue
		}
		// finished jobs are removed from .jobs at Finish/Fail time, so a
		// hit here is always claim-eligible.
		s.claimed[j.id] = true
		_ = i
		return &Job{
			ID:          j.id,
			ActiveJobID: j.activeJobID,
			QueueName:   j.queueName,
			Params:      j.params,
			EnqueuedAt:  j.enqueuedAt,
		}, nil
	}
	return nil, ErrNoJob
}

// Finish drops the claim and removes the job from the active queue.
func (s *InMemoryStore) Finish(_ context.Context, jobID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.claimed, jobID)
	s.finished[jobID] = "success"
	s.removeJobLocked(jobID)
	return nil
}

// Fail drops the claim, records the reason, removes the job.
func (s *InMemoryStore) Fail(_ context.Context, jobID, reason string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.claimed, jobID)
	s.finished[jobID] = reason
	s.removeJobLocked(jobID)
	return nil
}

func (s *InMemoryStore) removeJobLocked(jobID string) {
	for i, j := range s.jobs {
		if j.id == jobID {
			s.jobs = append(s.jobs[:i], s.jobs[i+1:]...)
			return
		}
	}
}

// Pending returns the count of jobs not yet in a terminal state.
func (s *InMemoryStore) Pending() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.jobs)
}

// FinishedState returns the terminal status recorded for a job ID, or
// the empty string if it's still pending.
func (s *InMemoryStore) FinishedState(jobID string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.finished[jobID]
}
