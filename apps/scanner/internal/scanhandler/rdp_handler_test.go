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

// Cf. openspec/changes/add-rdp-probe/tasks.md §2.1.

type fakeRDPProber struct {
	calls     atomic.Int64
	gotTarget string
	gotPort   int
	res       RDPProbeResult
}

func (f *fakeRDPProber) Probe(_ context.Context, target string, port int) (RDPProbeResult, error) {
	f.calls.Add(1)
	f.gotTarget = target
	f.gotPort = port
	return f.res, nil
}

func rdpFingerprintPayload(idemKey, targetKind, value string, findings []any, options map[string]any) map[string]any {
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

func TestRDPDispatch_Port3389InFindings_InvokesProber(t *testing.T) {
	prober := &fakeRDPProber{res: RDPProbeResult{
		ProtocolVersion: 0x00080004,
		SecurityFlags:   []string{"PROTOCOL_SSL", "PROTOCOL_HYBRID"},
		Outcome:         "success",
	}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{RDPProber: prober})

	job := goodjob.Job{ID: "x", Params: rdpFingerprintPayload(
		"sf-rdp-1", "host", "rdp.example.fr",
		[]any{
			map[string]any{"port": float64(3389)},
		},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Fatalf("expected 1 probe call, got %d", prober.calls.Load())
	}
	if prober.gotTarget != "rdp.example.fr" {
		t.Errorf("expected target=rdp.example.fr, got %q", prober.gotTarget)
	}
	if prober.gotPort != 3389 {
		t.Errorf("expected port=3389, got %d", prober.gotPort)
	}

	if store.Count() != 1 {
		t.Fatalf("expected 1 stored result, got %d", store.Count())
	}
	all, _ := store.List(context.Background())
	var got RDPProbeResult
	if err := json.Unmarshal([]byte(all[0].Status), &got); err != nil {
		t.Fatalf("unmarshal status: %v (raw=%q)", err, all[0].Status)
	}
	if got.Outcome != "success" {
		t.Errorf("expected outcome=success, got %q", got.Outcome)
	}
}

func TestRDPDispatch_NoPort3389_DoesNotInvokeProber(t *testing.T) {
	prober := &fakeRDPProber{}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{RDPProber: prober})

	job := goodjob.Job{ID: "x", Params: rdpFingerprintPayload(
		"sf-rdp-2", "host", "host.example.fr",
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

func TestRDPDispatch_OptionsProtocolsRDP_InvokesProber(t *testing.T) {
	prober := &fakeRDPProber{res: RDPProbeResult{Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{RDPProber: prober})

	job := goodjob.Job{ID: "x", Params: rdpFingerprintPayload(
		"sf-rdp-3", "ip", "192.0.2.20",
		nil,
		map[string]any{"protocols": []any{"rdp"}},
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Fatalf("expected 1 probe call (via options.protocols=rdp), got %d", prober.calls.Load())
	}
}

func TestRDPDispatch_NilProber_PersistsSkipped(t *testing.T) {
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{}) // pas de RDPProber

	job := goodjob.Job{ID: "x", Params: rdpFingerprintPayload(
		"sf-rdp-4", "host", "rdp.example.fr",
		[]any{map[string]any{"port": float64(3389)}},
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

func TestRDPDispatch_OtherTargetKind_NoProbe(t *testing.T) {
	prober := &fakeRDPProber{}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{RDPProber: prober})

	job := goodjob.Job{ID: "x", Params: rdpFingerprintPayload(
		"sf-rdp-5", "domain", "example.fr",
		[]any{map[string]any{"port": float64(3389)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 0 {
		t.Fatalf("expected 0 probe calls (target=domain), got %d", prober.calls.Load())
	}
}

// TestRDPDispatch_CohabitsWithSSH : port 22 → SSH, port 3389 → RDP.
// Le premier qui matche (SSH avant RDP dans le dispatch) gagne ; un
// payload avec UN seul port ne dérange pas l'autre prober.
func TestRDPDispatch_CohabitsWithSSH(t *testing.T) {
	sshProber := &fakeSSHProber{res: SSHProbeResult{Outcome: "success"}}
	rdpProber := &fakeRDPProber{res: RDPProbeResult{Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{SSHProber: sshProber, RDPProber: rdpProber})

	// Payload port=22 : SSH invoqué, RDP pas invoqué.
	job22 := goodjob.Job{ID: "j22", Params: rdpFingerprintPayload(
		"sf-coh-22", "host", "h.example.fr",
		[]any{map[string]any{"port": float64(22)}}, nil,
	)}
	if err := handler(context.Background(), job22); err != nil {
		t.Fatalf("handler 22: %v", err)
	}
	if sshProber.calls.Load() != 1 || rdpProber.calls.Load() != 0 {
		t.Fatalf("port 22: ssh=%d rdp=%d", sshProber.calls.Load(), rdpProber.calls.Load())
	}

	// Payload port=3389 : RDP invoqué, SSH pas réinvoqué.
	job3389 := goodjob.Job{ID: "j3389", Params: rdpFingerprintPayload(
		"sf-coh-3389", "host", "h.example.fr",
		[]any{map[string]any{"port": float64(3389)}}, nil,
	)}
	if err := handler(context.Background(), job3389); err != nil {
		t.Fatalf("handler 3389: %v", err)
	}
	if rdpProber.calls.Load() != 1 || sshProber.calls.Load() != 1 {
		t.Fatalf("port 3389: ssh=%d rdp=%d", sshProber.calls.Load(), rdpProber.calls.Load())
	}
}
