// Package worker - dispatch with panic recovery.
//
// Spec source: openspec/changes/add-tech-stack/specs/architecture/spec.md
//   Requirement: Scan Workers Runtime
//     Scenario: Crash d'un worker Go n'affecte pas l'API
// openspec/changes/add-tech-stack/tasks.md section 5.2.
//
// A panic inside a job handler must NOT take down the whole worker.
// Each job runs inside a dedicated goroutine with `defer recover()` so
// the worker keeps consuming the next jobs while a Prometheus counter
// records the panic and the offending job goes back to the retry path.

package worker

import (
	"context"
	"errors"
	"fmt"
	"runtime/debug"
	"sync/atomic"
)

// PanicError wraps a recovered panic value plus the goroutine stack so
// the caller can log it and surface it to the metrics layer.
type PanicError struct {
	Value any
	Stack []byte
}

func (p *PanicError) Error() string {
	return fmt.Sprintf("worker recovered panic: %v", p.Value)
}

// PanicCounter is the minimal interface needed to record a panic. The
// production binary wires this to a Prometheus counter named
// `scan_worker_panics_total`. Tests use a fake.
type PanicCounter interface {
	Inc()
}

// noopCounter is the default when no metrics backend is wired.
type noopCounter struct{ n atomic.Int64 }

func (c *noopCounter) Inc()        { c.n.Add(1) }
func (c *noopCounter) Value() int64 { return c.n.Load() }

// Handler is the unit of work scheduled per job. It returns an error or
// panics. Panics are caught by SafeRun and converted to a *PanicError.
type Handler func(ctx context.Context) error

// SafeRun runs handler under a recover() so a panic does not propagate
// out of the goroutine. Returns:
//   - nil if handler completes without error
//   - the handler's returned error
//   - *PanicError wrapping the panic value when handler panics
//
// `panics` is incremented on panic recovery (nil-safe).
func SafeRun(ctx context.Context, handler Handler, panics PanicCounter) (err error) {
	defer func() {
		if r := recover(); r != nil {
			if panics != nil {
				panics.Inc()
			}
			err = &PanicError{Value: r, Stack: debug.Stack()}
		}
	}()

	if handler == nil {
		return errors.New("nil handler")
	}
	return handler(ctx)
}

// NewNoopCounter returns a counter that just keeps an in-memory count.
// Useful for the default binary path before Prometheus is wired up, and
// for tests that need to assert "no panic recorded".
func NewNoopCounter() *noopCounter {
	return &noopCounter{}
}
