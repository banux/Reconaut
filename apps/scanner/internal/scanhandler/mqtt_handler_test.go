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

// Cf. openspec/changes/add-mqtt-probe/tasks.md §2.1.

type fakeMQTTProber struct {
	calls     atomic.Int64
	gotTarget string
	gotPort   int
	res       MQTTProbeResult
}

func (f *fakeMQTTProber) Probe(_ context.Context, target string, port int) (MQTTProbeResult, error) {
	f.calls.Add(1)
	f.gotTarget = target
	f.gotPort = port
	return f.res, nil
}

func mqttFingerprintPayload(idemKey, targetKind, value string, findings []any, options map[string]any) map[string]any {
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

func TestMQTTDispatch_Port1883_InvokesProber(t *testing.T) {
	prober := &fakeMQTTProber{res: MQTTProbeResult{ProtocolLevel: 4, ReturnCode: 0, ReturnCodeMeaning: "accepted", Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{MQTTProber: prober})

	job := goodjob.Job{ID: "x", Params: mqttFingerprintPayload(
		"sf-mqtt-1", "host", "mqtt.example.fr",
		[]any{map[string]any{"port": float64(1883)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Fatalf("expected 1 probe call, got %d", prober.calls.Load())
	}
	if prober.gotPort != 1883 {
		t.Errorf("expected port=1883, got %d", prober.gotPort)
	}

	all, _ := store.List(context.Background())
	var got MQTTProbeResult
	if err := json.Unmarshal([]byte(all[0].Status), &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.ReturnCodeMeaning != "accepted" {
		t.Errorf("expected accepted, got %q", got.ReturnCodeMeaning)
	}
}

func TestMQTTDispatch_Port8883_InvokesProber(t *testing.T) {
	prober := &fakeMQTTProber{res: MQTTProbeResult{Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{MQTTProber: prober})

	job := goodjob.Job{ID: "x", Params: mqttFingerprintPayload(
		"sf-mqtt-tls", "ip", "192.0.2.10",
		[]any{map[string]any{"port": float64(8883)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.gotPort != 8883 {
		t.Errorf("expected port=8883, got %d", prober.gotPort)
	}
}

func TestMQTTDispatch_OptionsProtocols_InvokesProber(t *testing.T) {
	prober := &fakeMQTTProber{res: MQTTProbeResult{Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{MQTTProber: prober})

	job := goodjob.Job{ID: "x", Params: mqttFingerprintPayload(
		"sf-mqtt-opt", "host", "broker.example.fr", nil,
		map[string]any{"protocols": []any{"mqtt"}},
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Fatalf("expected 1 probe call via options.protocols=mqtt, got %d", prober.calls.Load())
	}
}

func TestMQTTDispatch_OtherPort_NoProbe(t *testing.T) {
	prober := &fakeMQTTProber{}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{MQTTProber: prober})

	job := goodjob.Job{ID: "x", Params: mqttFingerprintPayload(
		"sf-mqtt-no", "host", "h.example.fr",
		[]any{map[string]any{"port": float64(443)}}, nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 0 {
		t.Fatalf("expected 0 probe calls, got %d", prober.calls.Load())
	}
}

func TestMQTTDispatch_NilProber_PersistsSkipped(t *testing.T) {
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{}) // pas de MQTTProber

	job := goodjob.Job{ID: "x", Params: mqttFingerprintPayload(
		"sf-mqtt-nil", "host", "h.example.fr",
		[]any{map[string]any{"port": float64(1883)}}, nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	all, _ := store.List(context.Background())
	if !strings.Contains(all[0].Status, "skipped") {
		t.Errorf("expected status to mention skipped, got %q", all[0].Status)
	}
}

// TestMQTTDispatch_CohabitsWithSSHAndRDP : port 22 → SSH, 3389 → RDP,
// 1883 → MQTT. Pas d'interférence.
func TestMQTTDispatch_CohabitsWithSSHAndRDP(t *testing.T) {
	sshProber := &fakeSSHProber{res: SSHProbeResult{Outcome: "success"}}
	rdpProber := &fakeRDPProber{res: RDPProbeResult{Outcome: "success"}}
	mqttProber := &fakeMQTTProber{res: MQTTProbeResult{Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{
		SSHProber: sshProber, RDPProber: rdpProber, MQTTProber: mqttProber,
	})

	cases := []struct {
		key  string
		port float64
		ssh  int64
		rdp  int64
		mqtt int64
	}{
		{"key-22-ssh", 22, 1, 0, 0},
		{"key-3389-rdp", 3389, 1, 1, 0},
		{"key-1883-mqtt", 1883, 1, 1, 1},
	}
	for _, c := range cases {
		job := goodjob.Job{ID: c.key, Params: mqttFingerprintPayload(
			c.key, "host", "h.example.fr",
			[]any{map[string]any{"port": c.port}}, nil,
		)}
		if err := handler(context.Background(), job); err != nil {
			t.Fatalf("handler[%s]: %v", c.key, err)
		}
		if sshProber.calls.Load() != c.ssh || rdpProber.calls.Load() != c.rdp || mqttProber.calls.Load() != c.mqtt {
			t.Fatalf("port %v: ssh=%d rdp=%d mqtt=%d (want %d %d %d)",
				c.port, sshProber.calls.Load(), rdpProber.calls.Load(), mqttProber.calls.Load(),
				c.ssh, c.rdp, c.mqtt)
		}
	}
}
