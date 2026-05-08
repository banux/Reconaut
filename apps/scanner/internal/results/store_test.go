package results

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

func TestInMemoryStore_InsertNew(t *testing.T) {
	s := NewInMemoryStore()
	r := Result{
		IdempotencyKey: "k1",
		ScanKind:       "tcp_probe",
		TargetKind:     "ip",
		TargetValue:    "192.0.2.1",
		Status:         "ok",
		ObservedAt:     time.Now(),
	}
	inserted, err := s.Insert(context.Background(), r)
	if err != nil {
		t.Fatalf("Insert: %v", err)
	}
	if !inserted {
		t.Errorf("expected inserted=true on a fresh key")
	}
	if got := s.Count(); got != 1 {
		t.Errorf("Count=%d, want 1", got)
	}
}

func TestInMemoryStore_DuplicateKey(t *testing.T) {
	s := NewInMemoryStore()
	r := Result{IdempotencyKey: "k1", Status: "ok"}
	_, _ = s.Insert(context.Background(), r)
	inserted, err := s.Insert(context.Background(), r)
	if err != nil {
		t.Fatalf("second Insert: %v", err)
	}
	if inserted {
		t.Error("expected inserted=false on duplicate key")
	}
	if got := s.Count(); got != 1 {
		t.Errorf("Count=%d, want 1", got)
	}
}

func TestInMemoryStore_RejectsEmptyKey(t *testing.T) {
	s := NewInMemoryStore()
	_, err := s.Insert(context.Background(), Result{})
	if !errors.Is(err, ErrMissingIdempotencyKey) {
		t.Fatalf("expected ErrMissingIdempotencyKey, got %v", err)
	}
}

func TestInMemoryStore_ConcurrentInserts(t *testing.T) {
	s := NewInMemoryStore()
	var wg sync.WaitGroup
	const N = 50
	wg.Add(N)
	for i := 0; i < N; i++ {
		i := i
		go func() {
			defer wg.Done()
			_, _ = s.Insert(context.Background(), Result{
				IdempotencyKey: "k",
				Status:         "ok",
			})
			_, _ = s.Insert(context.Background(), Result{
				IdempotencyKey: keyFor(i),
				Status:         "ok",
			})
		}()
	}
	wg.Wait()
	// 1 doublon "k" + N clés uniques
	if got := s.Count(); got != N+1 {
		t.Errorf("Count=%d, want %d", got, N+1)
	}
}

func keyFor(i int) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	return alphabet[i%len(alphabet) : i%len(alphabet)+1] + "-" + sprintInt(i)
}

func sprintInt(i int) string {
	if i == 0 {
		return "0"
	}
	digits := make([]byte, 0, 4)
	neg := i < 0
	if neg {
		i = -i
	}
	for i > 0 {
		digits = append([]byte{byte('0' + i%10)}, digits...)
		i /= 10
	}
	if neg {
		digits = append([]byte{'-'}, digits...)
	}
	return string(digits)
}
