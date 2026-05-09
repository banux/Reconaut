// SPDX-License-Identifier: AGPL-3.0-only
package scanhandler

import (
	"context"
	"encoding/json"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/goodjob"
	"github.com/banux/Reconaut/apps/scanner/internal/results"
)

// Cf. openspec/changes/add-ssh-probe/tasks.md §2.1.

type fakeSSHProber struct {
	calls      atomic.Int64
	gotTarget  string
	gotPort    int
	res        SSHProbeResult
}

func (f *fakeSSHProber) Probe(_ context.Context, target string, port int) (SSHProbeResult, error) {
	f.calls.Add(1)
	f.gotTarget = target
	f.gotPort = port
	return f.res, nil
}

func sshFingerprintPayload(idemKey, targetKind, value string, findings []any, options map[string]any) map[string]any {
	out := map[string]any{
		"schema_version":  float64(1),
		"idempotency_key": idemKey,
		"scan_kind":       "service_fingerprint",
		"target":          map[string]any{"kind": targetKind, "value": value},
		"requested_at":    time.Now().UTC().Format(time.RFC3339),
	}
	if findings != nil {
		out["findings"] = findings
	}
	if options != nil {
		out["options"] = options
	}
	return out
}

func TestSSHDispatch_Port22InFindings_InvokesProber(t *testing.T) {
	prober := &fakeSSHProber{res: SSHProbeResult{
		Banner:        "SSH-2.0-OpenSSH_8.9p1",
		HostKeySHA256: "SHA256:abcd",
		Outcome:       "success",
	}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{SSHProber: prober})

	job := goodjob.Job{ID: "x", Params: sshFingerprintPayload(
		"sf-key-1", "host", "host.example.fr",
		[]any{
			map[string]any{"port": float64(22)},
		},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Fatalf("expected 1 probe call, got %d", prober.calls.Load())
	}
	if prober.gotTarget != "host.example.fr" {
		t.Errorf("expected target=host.example.fr, got %q", prober.gotTarget)
	}
	if prober.gotPort != 22 {
		t.Errorf("expected port=22, got %d", prober.gotPort)
	}

	// Le résultat est sérialisé en JSON dans Status.
	if store.Count() != 1 {
		t.Fatalf("expected 1 stored result, got %d", store.Count())
	}
	all, _ := store.List(context.Background())
	if len(all) != 1 {
		t.Fatalf("expected 1 result, got %d", len(all))
	}
	var got SSHProbeResult
	if err := json.Unmarshal([]byte(all[0].Status), &got); err != nil {
		t.Fatalf("unmarshal status: %v (raw=%q)", err, all[0].Status)
	}
	if got.Outcome != "success" || !strings.HasPrefix(got.Banner, "SSH-") {
		t.Errorf("unexpected stored result: %+v", got)
	}
}

func TestSSHDispatch_NoPort22_DoesNotInvokeProber(t *testing.T) {
	prober := &fakeSSHProber{}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{SSHProber: prober})

	// Findings ne contient pas le port 22 → pas d'invocation.
	job := goodjob.Job{ID: "x", Params: sshFingerprintPayload(
		"sf-key-2", "host", "host.example.fr",
		[]any{
			map[string]any{"port": float64(443)},
			map[string]any{"port": float64(80)},
		},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 0 {
		t.Fatalf("expected 0 probe calls, got %d", prober.calls.Load())
	}
}

func TestSSHDispatch_OptionsProtocolsSSH_InvokesProber(t *testing.T) {
	prober := &fakeSSHProber{res: SSHProbeResult{Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{SSHProber: prober})

	job := goodjob.Job{ID: "x", Params: sshFingerprintPayload(
		"sf-key-3", "ip", "192.0.2.10",
		nil,
		map[string]any{"protocols": []any{"ssh"}},
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Fatalf("expected 1 probe call (via options.protocols=ssh), got %d", prober.calls.Load())
	}
}

func TestSSHDispatch_NilProber_PersistsSkipped(t *testing.T) {
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{}) // pas de SSHProber

	job := goodjob.Job{ID: "x", Params: sshFingerprintPayload(
		"sf-key-4", "host", "host.example.fr",
		[]any{map[string]any{"port": float64(22)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if store.Count() != 1 {
		t.Fatalf("expected 1 stored result (skipped), got %d", store.Count())
	}
	all, _ := store.List(context.Background())
	if !strings.Contains(all[0].Status, "skipped") {
		t.Errorf("expected status to mention skipped, got %q", all[0].Status)
	}
}

func TestSSHDispatch_OtherTargetKind_NoProbe(t *testing.T) {
	prober := &fakeSSHProber{}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{SSHProber: prober})

	// target_kind=domain : la sonde SSH n'est pas appropriée (un
	// domaine résout vers N IPs, le sondeur SSH s'invoque par IP).
	job := goodjob.Job{ID: "x", Params: sshFingerprintPayload(
		"sf-key-5", "domain", "example.fr",
		[]any{map[string]any{"port": float64(22)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 0 {
		t.Fatalf("expected 0 probe calls (target=domain), got %d", prober.calls.Load())
	}
}
