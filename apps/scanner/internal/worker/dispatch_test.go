// SPDX-License-Identifier: AGPL-3.0-only
package worker

import (
	"context"
	"errors"
	"testing"
)

func TestSafeRun_HappyPath(t *testing.T) {
	counter := NewNoopCounter()
	called := false

	err := SafeRun(context.Background(), func(ctx context.Context) error {
		called = true
		return nil
	}, counter)

	if err != nil {
		t.Fatalf("expected nil, got %v", err)
	}
	if !called {
		t.Fatal("handler was not called")
	}
	if counter.Value() != 0 {
		t.Fatalf("expected 0 panics, got %d", counter.Value())
	}
}

func TestSafeRun_PropagatesError(t *testing.T) {
	counter := NewNoopCounter()
	wantErr := errors.New("boom")

	err := SafeRun(context.Background(), func(ctx context.Context) error {
		return wantErr
	}, counter)

	if err != wantErr {
		t.Fatalf("expected wantErr, got %v", err)
	}
	if counter.Value() != 0 {
		t.Fatalf("error path should not increment panic counter, got %d", counter.Value())
	}
}

func TestSafeRun_RecoversPanic(t *testing.T) {
	counter := NewNoopCounter()

	err := SafeRun(context.Background(), func(ctx context.Context) error {
		panic("kaboom")
	}, counter)

	if err == nil {
		t.Fatal("expected non-nil error after panic recovery")
	}
	pe, ok := err.(*PanicError)
	if !ok {
		t.Fatalf("expected *PanicError, got %T", err)
	}
	if pe.Value != "kaboom" {
		t.Fatalf("unexpected panic value: %v", pe.Value)
	}
	if len(pe.Stack) == 0 {
		t.Fatal("expected non-empty stack trace")
	}
	if counter.Value() != 1 {
		t.Fatalf("expected 1 panic recorded, got %d", counter.Value())
	}
}

func TestSafeRun_RecoversNonStringPanic(t *testing.T) {
	counter := NewNoopCounter()

	err := SafeRun(context.Background(), func(ctx context.Context) error {
		var nilMap map[string]int
		nilMap["x"] = 1 // runtime panic
		return nil
	}, counter)

	if err == nil {
		t.Fatal("expected non-nil error after runtime panic")
	}
	if _, ok := err.(*PanicError); !ok {
		t.Fatalf("expected *PanicError, got %T", err)
	}
	if counter.Value() != 1 {
		t.Fatalf("expected 1 panic, got %d", counter.Value())
	}
}

func TestSafeRun_NilHandler(t *testing.T) {
	counter := NewNoopCounter()
	err := SafeRun(context.Background(), nil, counter)
	if err == nil {
		t.Fatal("expected error for nil handler")
	}
	if counter.Value() != 0 {
		t.Fatalf("nil handler is not a panic, counter should stay 0")
	}
}

// Materialise le scenario "Le worker continue de consommer apres un panic"
// de add-tech-stack section 5.2 : on lance 5 handlers de suite ; le 3eme
// panique ; les 4 autres terminent proprement.
func TestSafeRun_KeepsConsumingAfterPanic(t *testing.T) {
	counter := NewNoopCounter()
	processed := 0

	for i := 0; i < 5; i++ {
		i := i // capture
		_ = SafeRun(context.Background(), func(ctx context.Context) error {
			if i == 2 {
				panic("middle job died")
			}
			processed++
			return nil
		}, counter)
	}

	if processed != 4 {
		t.Fatalf("expected 4 jobs processed (1 panicked), got %d", processed)
	}
	if counter.Value() != 1 {
		t.Fatalf("expected exactly 1 panic, got %d", counter.Value())
	}
}

// Verifie que SafeRun n'avale pas le ctx.Err() : si le handler retourne
// l'erreur d'annulation, elle remonte intacte.
func TestSafeRun_PreservesContextCancellation(t *testing.T) {
	counter := NewNoopCounter()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err := SafeRun(ctx, func(ctx context.Context) error {
		return ctx.Err()
	}, counter)

	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
}
