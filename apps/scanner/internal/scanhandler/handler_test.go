// SPDX-License-Identifier: AGPL-3.0-only
package scanhandler

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/goodjob"
	"github.com/banux/Reconaut/apps/scanner/internal/results"
)

// Cf. openspec/changes/add-tech-stack/tasks.md §5.1 :
// "lance 2 workers Go sur la même DB, enqueue 100 jobs (dont 10
//  doublons par idempotency_key) ; assure que (a) tous les jobs
//  uniques sont traités, (b) les doublons sont détectés et acquittés
//  sans seconde écriture, (c) la charge est répartie (chaque worker
//  traite > 30 % du volume unique)."

func enqueueJobs(t *testing.T, store *goodjob.InMemoryStore, total, duplicates int) {
	t.Helper()
	uniqueCount := total - duplicates
	for i := 0; i < uniqueCount; i++ {
		jobID := fmt.Sprintf("job-%03d", i)
		idemKey := fmt.Sprintf("scan-key-%05d", i)
		store.Enqueue(jobID, jobID, "scan", validPayload(idemKey, i))
	}
	// duplicate jobs reuse the first `duplicates` idempotency_keys
	// already enqueued above
	for i := 0; i < duplicates; i++ {
		jobID := fmt.Sprintf("job-dup-%03d", i)
		idemKey := fmt.Sprintf("scan-key-%05d", i) // same as job i
		store.Enqueue(jobID, jobID, "scan", validPayload(idemKey, i))
	}
}

func validPayload(idemKey string, n int) map[string]any {
	return map[string]any{
		"schema_version":  float64(1),
		"idempotency_key": idemKey,
		"scan_kind":       "tcp_probe",
		"target": map[string]any{
			"kind":  "ip",
			"value": fmt.Sprintf("192.0.2.%d", (n%254)+1),
		},
		"requested_at": time.Now().UTC().Format(time.RFC3339),
	}
}

func TestScanHandler_PersistsResultWithIdempotency(t *testing.T) {
	jobStore := goodjob.NewInMemoryStore()
	resStore := results.NewInMemoryStore()
	handler := New(resStore, nil)

	jobStore.Enqueue("j1", "j1", "scan", validPayload("scan-key-A", 0))

	job, err := jobStore.Claim(context.Background(), "scan")
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	if err := handler(context.Background(), *job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if resStore.Count() != 1 {
		t.Fatalf("expected 1 result inserted, got %d", resStore.Count())
	}
}

func TestScanHandler_RejectsInvalidPayload(t *testing.T) {
	resStore := results.NewInMemoryStore()
	handler := New(resStore, nil)

	bad := map[string]any{
		"schema_version": float64(99), // const "1" expected
	}
	err := handler(context.Background(), goodjob.Job{ID: "x", Params: bad})
	if err == nil {
		t.Fatal("expected error on invalid payload, got nil")
	}
	if resStore.Count() != 0 {
		t.Fatalf("no result should be inserted on invalid payload, got %d", resStore.Count())
	}
}

func TestScanHandler_DuplicateIdempotencyIsNotAnError(t *testing.T) {
	resStore := results.NewInMemoryStore()
	handler := New(resStore, nil)

	job := goodjob.Job{ID: "x", Params: validPayload("scan-key-dup", 0)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("first call: %v", err)
	}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("second (dup) call: %v", err)
	}
	if resStore.Count() != 1 {
		t.Fatalf("dup should not be inserted; expected 1 result, got %d", resStore.Count())
	}
}

func TestWorker_TwoWorkersShare100JobsWith10Duplicates(t *testing.T) {
	const (
		totalEnqueued    = 110 // 100 unique + 10 duplicates
		uniqueExpected   = 100
		duplicateExpected = 10
	)

	jobStore := goodjob.NewInMemoryStore()
	resStore := results.NewInMemoryStore()
	enqueueJobs(t, jobStore, totalEnqueued, duplicateExpected)

	handler := New(resStore, nil)

	// Track how many jobs each worker processed to assert load balance.
	var workerCounts [2]atomic.Int64
	makeWrapper := func(idx int) goodjob.Handler {
		return func(ctx context.Context, job goodjob.Job) error {
			workerCounts[idx].Add(1)
			return handler(ctx, job)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Watcher : annule le contexte dès que la file est drainée. Évite
	// d'attendre le timeout naturel des `MaxJobs` quand la charge se
	// répartit asymétriquement entre les deux workers.
	go func() {
		ticker := time.NewTicker(2 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if jobStore.Pending() == 0 {
					cancel()
					return
				}
			}
		}
	}()

	var wg sync.WaitGroup
	wg.Add(2)
	for i := 0; i < 2; i++ {
		idx := i
		go func() {
			defer wg.Done()
			_, err := goodjob.Loop(ctx, jobStore, makeWrapper(idx), goodjob.LoopConfig{
				Queue:       "scan",
				IdleBackoff: 1 * time.Millisecond,
			})
			if err != nil {
				t.Errorf("worker %d Loop error: %v", idx, err)
			}
		}()
	}
	wg.Wait()

	// (a) tous les jobs uniques traités → uniqueExpected lignes en results.
	if got := resStore.Count(); got != uniqueExpected {
		t.Fatalf("expected %d unique results, got %d", uniqueExpected, got)
	}

	// (b) doublons détectés sans seconde écriture : count == unique
	//     (déjà vérifié ci-dessus). On vérifie aussi qu'aucun job n'est
	//     resté pending dans le goodjob store.
	if pending := jobStore.Pending(); pending != 0 {
		t.Errorf("expected 0 pending jobs, got %d", pending)
	}

	// (c) charge répartie : chaque worker > 30 % du total claim.
	w0, w1 := workerCounts[0].Load(), workerCounts[1].Load()
	totalClaimed := w0 + w1
	threshold := int64(float64(totalClaimed) * 0.30)
	if w0 < threshold || w1 < threshold {
		t.Errorf("load not balanced (>30%% each) : w0=%d w1=%d (total=%d, threshold=%d)",
			w0, w1, totalClaimed, threshold)
	}
}
