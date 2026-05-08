package goodjob

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/worker"
)

func samplePayload() map[string]any {
	return map[string]any{
		"schema_version":  float64(1),
		"idempotency_key": "scan-20260508-1200-deadbeefcafebabe",
		"scan_kind":       "tcp_port_scan",
		"target": map[string]any{
			"kind":  "ip",
			"value": "192.0.2.10",
		},
		"requested_at": "2026-05-08T12:00:00Z",
	}
}

func TestParseSerializedParams_RoundTrip(t *testing.T) {
	t.Parallel()
	payload := samplePayload()
	raw, err := EncodeSerializedParams(payload)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	got, err := ParseSerializedParams(raw)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	want, _ := json.Marshal(payload)
	gotJSON, _ := json.Marshal(got)
	if !bytes.Equal(want, gotJSON) {
		t.Fatalf("mismatch:\n want=%s\n got =%s", want, gotJSON)
	}
}

func TestParseSerializedParams_RejectsMalformed(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		raw  []byte
	}{
		{"empty", []byte{}},
		{"not json", []byte("not json")},
		{"no arguments", []byte(`{"job_class":"ScanJob"}`)},
		{"empty arguments", []byte(`{"arguments":[]}`)},
		{"first arg not object", []byte(`{"arguments":["string"]}`)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := ParseSerializedParams(tc.raw); err == nil {
				t.Fatalf("expected error for %q", tc.name)
			}
		})
	}
}

func TestInMemoryStore_BasicLifecycle(t *testing.T) {
	t.Parallel()
	s := NewInMemoryStore()
	s.Enqueue("job-1", "aj-1", "scan", samplePayload())

	if s.Pending() != 1 {
		t.Fatalf("pending=%d, want 1", s.Pending())
	}

	job, err := s.Claim(context.Background(), "scan")
	if err != nil {
		t.Fatalf("claim: %v", err)
	}
	if job.ID != "job-1" {
		t.Fatalf("job id=%q, want job-1", job.ID)
	}

	if err := s.Finish(context.Background(), "job-1"); err != nil {
		t.Fatalf("finish: %v", err)
	}
	if s.FinishedState("job-1") != "success" {
		t.Fatalf("finished state=%q, want success", s.FinishedState("job-1"))
	}
	if s.Pending() != 0 {
		t.Fatalf("pending=%d, want 0", s.Pending())
	}
}

func TestInMemoryStore_ClaimSkipsLocked(t *testing.T) {
	t.Parallel()
	s := NewInMemoryStore()
	s.Enqueue("job-A", "aj-A", "scan", samplePayload())
	s.Enqueue("job-B", "aj-B", "scan", samplePayload())

	first, err := s.Claim(context.Background(), "scan")
	if err != nil {
		t.Fatalf("claim 1: %v", err)
	}

	second, err := s.Claim(context.Background(), "scan")
	if err != nil {
		t.Fatalf("claim 2: %v", err)
	}
	if first.ID == second.ID {
		t.Fatalf("two claims got same job %q", first.ID)
	}

	// A third claim with the queue empty (both locked) returns ErrNoJob.
	if _, err := s.Claim(context.Background(), "scan"); !errors.Is(err, ErrNoJob) {
		t.Fatalf("expected ErrNoJob, got %v", err)
	}
}

func TestInMemoryStore_ClaimRespectsQueueFilter(t *testing.T) {
	t.Parallel()
	s := NewInMemoryStore()
	s.Enqueue("job-other", "aj", "default", samplePayload())

	if _, err := s.Claim(context.Background(), "scan"); !errors.Is(err, ErrNoJob) {
		t.Fatalf("expected ErrNoJob (queue mismatch), got %v", err)
	}
}

func TestLoop_HandlesJobsAndExitsAtMax(t *testing.T) {
	t.Parallel()
	s := NewInMemoryStore()
	for i := range 5 {
		s.Enqueue(jobID(i), "aj", "scan", samplePayload())
	}

	var handled atomic.Int64
	processed, err := Loop(context.Background(), s, func(_ context.Context, j Job) error {
		handled.Add(1)
		_ = j
		return nil
	}, LoopConfig{Queue: "scan", MaxJobs: 5, IdleBackoff: time.Millisecond})
	if err != nil {
		t.Fatalf("loop: %v", err)
	}
	if processed != 5 {
		t.Fatalf("processed=%d, want 5", processed)
	}
	if handled.Load() != 5 {
		t.Fatalf("handled=%d, want 5", handled.Load())
	}
	for i := range 5 {
		if state := s.FinishedState(jobID(i)); state != "success" {
			t.Fatalf("job %s state=%q, want success", jobID(i), state)
		}
	}
}

func TestLoop_PanicInHandlerMarksFailedAndContinues(t *testing.T) {
	t.Parallel()
	s := NewInMemoryStore()
	s.Enqueue("job-panic", "aj", "scan", samplePayload())
	s.Enqueue("job-ok", "aj", "scan", samplePayload())

	panicCounter := worker.NewNoopCounter()
	processed, err := Loop(context.Background(), s, func(_ context.Context, j Job) error {
		if j.ID == "job-panic" {
			panic("boom")
		}
		return nil
	}, LoopConfig{Queue: "scan", MaxJobs: 2, IdleBackoff: time.Millisecond, PanicCounter: panicCounter})
	if err != nil {
		t.Fatalf("loop: %v", err)
	}
	if processed != 2 {
		t.Fatalf("processed=%d, want 2", processed)
	}
	if state := s.FinishedState("job-panic"); state == "" || state == "success" {
		t.Fatalf("expected job-panic to be failed, got %q", state)
	}
	if state := s.FinishedState("job-ok"); state != "success" {
		t.Fatalf("expected job-ok to be success, got %q", state)
	}
	if panicCounter.Value() != 1 {
		t.Fatalf("panic counter=%d, want 1", panicCounter.Value())
	}
}

func TestLoop_ReturnedErrorMarksFailed(t *testing.T) {
	t.Parallel()
	s := NewInMemoryStore()
	s.Enqueue("job-err", "aj", "scan", samplePayload())
	processed, err := Loop(context.Background(), s, func(_ context.Context, _ Job) error {
		return errors.New("downstream Postgres unreachable")
	}, LoopConfig{Queue: "scan", MaxJobs: 1, IdleBackoff: time.Millisecond})
	if err != nil {
		t.Fatalf("loop: %v", err)
	}
	if processed != 1 {
		t.Fatalf("processed=%d, want 1", processed)
	}
	got := s.FinishedState("job-err")
	if got != "downstream Postgres unreachable" {
		t.Fatalf("failed reason=%q", got)
	}
}

func TestLoop_StopsOnContextCancel(t *testing.T) {
	t.Parallel()
	s := NewInMemoryStore() // empty queue forces idle backoff
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	processed, err := Loop(ctx, s, func(_ context.Context, _ Job) error { return nil },
		LoopConfig{Queue: "scan", IdleBackoff: 10 * time.Millisecond})
	if err != nil {
		t.Fatalf("loop: %v", err)
	}
	if processed != 0 {
		t.Fatalf("processed=%d, want 0", processed)
	}
}

func jobID(i int) string {
	return "job-" + string(rune('A'+i))
}
