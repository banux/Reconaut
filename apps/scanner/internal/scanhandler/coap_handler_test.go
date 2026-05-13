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

// Cf. openspec/changes/add-coap-probe/tasks.md §2.1.

type fakeCoAPProber struct {
	calls     atomic.Int64
	gotTarget string
	gotPort   int
	res       CoAPProbeResult
}

func (f *fakeCoAPProber) Probe(_ context.Context, target string, port int) (CoAPProbeResult, error) {
	f.calls.Add(1)
	f.gotTarget = target
	f.gotPort = port
	return f.res, nil
}

func coapFingerprintPayload(idemKey, targetKind, value string, findings []any, options map[string]any) map[string]any {
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

func TestCoAPDispatch_Port5683_InvokesProber(t *testing.T) {
	prober := &fakeCoAPProber{res: CoAPProbeResult{
		ResponseCodeClass: 2, ResponseCodeDetail: 5,
		ResponseCodeMeaning: "2.05 Content", ContentFormat: 40,
		Outcome: "success",
	}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{CoAPProber: prober})

	job := goodjob.Job{ID: "x", Params: coapFingerprintPayload(
		"sf-coap-1", "host", "iot.example.fr",
		[]any{map[string]any{"port": float64(5683)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Fatalf("expected 1 probe call, got %d", prober.calls.Load())
	}
	if prober.gotPort != 5683 {
		t.Errorf("expected port=5683, got %d", prober.gotPort)
	}

	all, _ := store.List(context.Background())
	var got CoAPProbeResult
	if err := json.Unmarshal([]byte(all[0].Status), &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.ResponseCodeMeaning != "2.05 Content" {
		t.Errorf("expected 2.05 Content, got %q", got.ResponseCodeMeaning)
	}
}

func TestCoAPDispatch_OptionsProtocols(t *testing.T) {
	prober := &fakeCoAPProber{res: CoAPProbeResult{Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{CoAPProber: prober})

	job := goodjob.Job{ID: "x", Params: coapFingerprintPayload(
		"sf-coap-2", "ip", "192.0.2.10", nil,
		map[string]any{"protocols": []any{"coap"}},
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Fatalf("expected 1 probe call via options.protocols=coap, got %d", prober.calls.Load())
	}
}

func TestCoAPDispatch_OtherPort_NoProbe(t *testing.T) {
	prober := &fakeCoAPProber{}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{CoAPProber: prober})

	job := goodjob.Job{ID: "x", Params: coapFingerprintPayload(
		"sf-coap-3", "host", "h.example.fr",
		[]any{map[string]any{"port": float64(80)}}, nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 0 {
		t.Fatalf("expected 0 probe calls, got %d", prober.calls.Load())
	}
}

func TestCoAPDispatch_NilProber_PersistsSkipped(t *testing.T) {
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{}) // pas de CoAPProber

	job := goodjob.Job{ID: "x", Params: coapFingerprintPayload(
		"sf-coap-4", "host", "h.example.fr",
		[]any{map[string]any{"port": float64(5683)}}, nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	all, _ := store.List(context.Background())
	if !strings.Contains(all[0].Status, "skipped") {
		t.Errorf("expected status to mention skipped, got %q", all[0].Status)
	}
}

// TestCoAPDispatch_FourCohabits : SSH(22) + RDP(3389) + MQTT(1883) +
// CoAP(5683) doivent cohabiter dans le même dispatch sans
// interférence.
func TestCoAPDispatch_FourCohabits(t *testing.T) {
	sshProber := &fakeSSHProber{res: SSHProbeResult{Outcome: "success"}}
	rdpProber := &fakeRDPProber{res: RDPProbeResult{Outcome: "success"}}
	mqttProber := &fakeMQTTProber{res: MQTTProbeResult{Outcome: "success"}}
	coapProber := &fakeCoAPProber{res: CoAPProbeResult{Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{
		SSHProber: sshProber, RDPProber: rdpProber,
		MQTTProber: mqttProber, CoAPProber: coapProber,
	})

	cases := []struct {
		key   string
		port  float64
		ssh   int64
		rdp   int64
		mqtt  int64
		coap  int64
	}{
		{"key-22-ssh", 22, 1, 0, 0, 0},
		{"key-3389-rdp", 3389, 1, 1, 0, 0},
		{"key-1883-mqtt", 1883, 1, 1, 1, 0},
		{"key-5683-coap", 5683, 1, 1, 1, 1},
	}
	for _, c := range cases {
		job := goodjob.Job{ID: c.key, Params: coapFingerprintPayload(
			c.key, "host", "h.example.fr",
			[]any{map[string]any{"port": c.port}}, nil,
		)}
		if err := handler(context.Background(), job); err != nil {
			t.Fatalf("handler[%s]: %v", c.key, err)
		}
		if sshProber.calls.Load() != c.ssh || rdpProber.calls.Load() != c.rdp ||
			mqttProber.calls.Load() != c.mqtt || coapProber.calls.Load() != c.coap {
			t.Fatalf("port %v: ssh=%d rdp=%d mqtt=%d coap=%d (want %d %d %d %d)",
				c.port,
				sshProber.calls.Load(), rdpProber.calls.Load(),
				mqttProber.calls.Load(), coapProber.calls.Load(),
				c.ssh, c.rdp, c.mqtt, c.coap)
		}
	}
}
