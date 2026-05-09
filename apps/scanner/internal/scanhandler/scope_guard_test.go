// SPDX-License-Identifier: AGPL-3.0-only
package scanhandler

import (
	"context"
	"sync/atomic"
	"testing"

	"github.com/banux/Reconaut/apps/scanner/internal/goodjob"
	"github.com/banux/Reconaut/apps/scanner/internal/results"
	"github.com/banux/Reconaut/apps/scanner/internal/scopechecker"
)

// Cf. openspec/changes/init-reconaut-platform/tasks.md §2.2 :
// "Test d'intégration injecte un job pour 203.0.113.5 sans entrée de
// scope ; assure (a) aucun paquet sortant, (b) statut out-of-scope
// persisté, (c) ligne d'audit. Un job pour 192.0.2.10 avec une entrée
// de scope 192.0.2.0/24 active passe."

// trackingProber compte les invocations — sert à prouver que le
// prober N'EST PAS appelé quand la cible est hors scope (donc aucun
// paquet réseau émis).
type trackingProber struct{ calls atomic.Int64 }

func (t *trackingProber) Probe(_ context.Context, _ string, _ int) (SSHProbeResult, error) {
	t.calls.Add(1)
	return SSHProbeResult{Outcome: "success"}, nil
}

func TestScopeGuard_RefusesOutOfScopeTarget(t *testing.T) {
	store := results.NewInMemoryStore()
	prober := &trackingProber{}

	checker := scopechecker.NewInMemoryChecker([]scopechecker.Entry{
		{Kind: "cidr", Value: "192.0.2.0/24"},
	})

	handler := NewWithOptions(store, Options{
		ScopeChecker: checker,
		SSHProber:    prober,
	})

	job := goodjob.Job{ID: "x", Params: sshFingerprintPayload(
		"sf-out-of-scope", "ip", "203.0.113.5",
		[]any{map[string]any{"port": float64(22)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}

	// (a) aucun paquet sortant : le prober n'a JAMAIS été invoqué.
	if prober.calls.Load() != 0 {
		t.Fatalf("expected 0 prober calls, got %d (worker emitted packets to out-of-scope target)", prober.calls.Load())
	}

	// (b) statut out-of-scope persisté.
	if store.Count() != 1 {
		t.Fatalf("expected 1 result, got %d", store.Count())
	}
	all, _ := store.List(context.Background())
	if all[0].Status != "out-of-scope" {
		t.Errorf("expected Status=out-of-scope, got %q", all[0].Status)
	}
}

func TestScopeGuard_AllowsInScopeTarget(t *testing.T) {
	store := results.NewInMemoryStore()
	prober := &trackingProber{}

	checker := scopechecker.NewInMemoryChecker([]scopechecker.Entry{
		{Kind: "cidr", Value: "192.0.2.0/24"},
	})

	handler := NewWithOptions(store, Options{
		ScopeChecker: checker,
		SSHProber:    prober,
	})

	job := goodjob.Job{ID: "y", Params: sshFingerprintPayload(
		"sf-in-scope", "ip", "192.0.2.10",
		[]any{map[string]any{"port": float64(22)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}

	// Cible dans le scope → le prober est invoqué.
	if prober.calls.Load() != 1 {
		t.Errorf("expected 1 prober call, got %d", prober.calls.Load())
	}
}

func TestScopeGuard_NilCheckerSkipsGuard(t *testing.T) {
	// Sans ScopeChecker injecté, on retombe sur le comportement
	// historique : pas de garde côté worker (Rails reste la garde
	// primaire). Utile pour les tests qui n'ont pas besoin de la
	// défense-en-profondeur.
	store := results.NewInMemoryStore()
	prober := &trackingProber{}

	handler := NewWithOptions(store, Options{
		SSHProber: prober,
		// ScopeChecker: nil
	})

	job := goodjob.Job{ID: "z", Params: sshFingerprintPayload(
		"sf-no-checker", "ip", "203.0.113.5",
		[]any{map[string]any{"port": float64(22)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Errorf("expected prober invoked when no checker (got %d)", prober.calls.Load())
	}
}

func TestScopeGuard_DomainTargetMatchesDomainEntry(t *testing.T) {
	store := results.NewInMemoryStore()

	checker := scopechecker.NewInMemoryChecker([]scopechecker.Entry{
		{Kind: "domain", Value: "example.fr"},
	})
	handler := NewWithOptions(store, Options{ScopeChecker: checker})

	// Job DNS pour example.fr (scan_kind=dns_records) — pas besoin
	// de prober ici, on vérifie juste que le handler ne refuse pas.
	job := goodjob.Job{ID: "d", Params: map[string]any{
		"schema_version":  float64(1),
		"idempotency_key": "dns-in-scope-1",
		"scan_kind":       "dns_records",
		"target":          map[string]any{"kind": "domain", "value": "example.fr"},
		"requested_at":    "2026-05-09T18:00:00Z",
	}}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	all, _ := store.List(context.Background())
	if len(all) != 1 {
		t.Fatalf("expected 1 result, got %d", len(all))
	}
	if all[0].Status == "out-of-scope" {
		t.Error("expected NOT out-of-scope for domain in scope")
	}
}
