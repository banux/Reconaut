// SPDX-License-Identifier: AGPL-3.0-only
// Package goodjob — polling loop with panic recovery.

package goodjob

import (
	"context"
	"errors"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/worker"
)

// Handler is the unit of work invoked per claimed job. It receives the
// parsed Job and returns nil on success or a non-nil error on failure.
// A panic is caught by the loop (via worker.SafeRun) and recorded as a
// failure reason "panic: <value>".
type Handler func(ctx context.Context, job Job) error

// LoopConfig parameterizes the polling loop.
type LoopConfig struct {
	// Queue is the ActiveJob queue name to consume (e.g. "scan").
	Queue string
	// IdleBackoff is how long to sleep after Claim returns ErrNoJob.
	// Defaults to 1 second when zero.
	IdleBackoff time.Duration
	// MaxJobs limits the total number of jobs processed before the
	// loop exits cleanly. Zero means "run until ctx is cancelled".
	// Set in tests to make assertions deterministic.
	MaxJobs int
	// PanicCounter records how many times a handler panicked.
	PanicCounter worker.PanicCounter
}

// Loop runs the consume / handle / mark-finished cycle until either
// ctx is cancelled or MaxJobs jobs have been processed.
//
// Errors from Claim other than ErrNoJob are returned to the caller —
// they typically indicate Postgres connectivity issues that warrant a
// restart of the worker process.
//
// Returns the number of jobs successfully claimed (whether they
// succeeded or failed) and the terminating error (nil on clean exit
// from MaxJobs or ctx.Done()).
func Loop(ctx context.Context, store Store, handler Handler, cfg LoopConfig) (int, error) {
	if cfg.IdleBackoff <= 0 {
		cfg.IdleBackoff = time.Second
	}
	if cfg.PanicCounter == nil {
		cfg.PanicCounter = worker.NewNoopCounter()
	}

	processed := 0
	for {
		if cfg.MaxJobs > 0 && processed >= cfg.MaxJobs {
			return processed, nil
		}
		select {
		case <-ctx.Done():
			return processed, nil
		default:
		}

		job, err := store.Claim(ctx, cfg.Queue)
		if errors.Is(err, ErrNoJob) {
			if !sleepCtx(ctx, cfg.IdleBackoff) {
				return processed, nil
			}
			continue
		}
		if err != nil {
			return processed, err
		}

		runErr := worker.SafeRun(ctx, func(ctx context.Context) error {
			return handler(ctx, *job)
		}, cfg.PanicCounter)

		if runErr != nil {
			reason := runErr.Error()
			var pErr *worker.PanicError
			if errors.As(runErr, &pErr) {
				reason = "panic: " + pErr.Error()
			}
			if fErr := store.Fail(ctx, job.ID, reason); fErr != nil {
				return processed, fErr
			}
		} else {
			if fErr := store.Finish(ctx, job.ID); fErr != nil {
				return processed, fErr
			}
		}
		processed++
	}
}

// sleepCtx sleeps for d or returns false when ctx is cancelled first.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	select {
	case <-time.After(d):
		return true
	case <-ctx.Done():
		return false
	}
}
