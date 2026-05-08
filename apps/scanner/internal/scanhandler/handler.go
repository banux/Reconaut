// Package scanhandler builds the goodjob.Handler executed per scan
// job by the scanner-worker binary.
//
// Spec source: openspec/changes/add-tech-stack/tasks.md §5.1.
//
// New builds a goodjob.Handler that:
//
//  1. Validates the claimed job's params against ScanJobV1.
//  2. Runs the placeholder no-op scan (the real probes are the change
//     `scan-engine-<protocol>`'s job).
//  3. Persists a Result keyed by the payload's idempotency_key. The
//     results.Store applies "insert if new" semantics — replays of the
//     same idempotency_key are detected and acquitted without a second
//     write.
//
// The handler returns a non-nil error only on hard failures (schema
// invalid, store down). A duplicate idempotency_key is NOT an error;
// it's the expected idempotent-replay behaviour and the job is marked
// finished normally.
//
// Standalone package (not under internal/worker) to keep the import
// graph acyclic : goodjob imports worker for SafeRun, scanhandler
// imports both goodjob and results.

package scanhandler

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/goodjob"
	"github.com/banux/Reconaut/apps/scanner/internal/jobschema"
	"github.com/banux/Reconaut/apps/scanner/internal/results"
)

// NewScanHandler returns a goodjob.Handler that delegates to the
// supplied results.Store for persistence. `clock` is injectable so
// tests can pin observation timestamps.
func New(store results.Store, clock func() time.Time) goodjob.Handler {
	if clock == nil {
		clock = time.Now
	}
	return func(ctx context.Context, job goodjob.Job) error {
		raw, err := json.Marshal(job.Params)
		if err != nil {
			return fmt.Errorf("scan_handler: marshal params: %w", err)
		}
		errs, err := jobschema.Validate(jobschema.NameScanJobV1, raw)
		if err != nil {
			return fmt.Errorf("scan_handler: validate %s: %w", jobschema.NameScanJobV1, err)
		}
		if len(errs) > 0 {
			return fmt.Errorf("scan_handler: invalid ScanJobV1: %v", errs)
		}

		idemKey, _ := job.Params["idempotency_key"].(string)
		scanKind, _ := job.Params["scan_kind"].(string)
		targetKind, targetValue := extractTarget(job.Params)

		// Placeholder no-op : la vraie sonde sera livrée par les
		// changes `scan-engine-<protocol>`. On enregistre simplement
		// un résultat "ok" pour matérialiser le passage du worker.
		result := results.Result{
			IdempotencyKey: idemKey,
			ScanKind:       scanKind,
			TargetKind:     targetKind,
			TargetValue:    targetValue,
			Status:         "ok",
			ObservedAt:     clock().UTC(),
		}

		_, err = store.Insert(ctx, result)
		if err != nil {
			return fmt.Errorf("scan_handler: persist result: %w", err)
		}
		// inserted=false (duplicate) is NOT an error : c'est la
		// sémantique d'idempotence. On laisse le job se marquer
		// finished normalement côté goodjob.Loop.
		return nil
	}
}

func extractTarget(params map[string]any) (string, string) {
	target, ok := params["target"].(map[string]any)
	if !ok {
		return "", ""
	}
	kind, _ := target["kind"].(string)
	value, _ := target["value"].(string)
	return kind, value
}
