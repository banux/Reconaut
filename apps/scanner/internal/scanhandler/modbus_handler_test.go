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

// Cf. openspec/changes/add-worker-modbus/tasks.md §2.1.

type fakeModbusProber struct {
	calls     atomic.Int64
	gotTarget string
	gotPort   int
	res       ModbusProbeResult
}

func (f *fakeModbusProber) Probe(_ context.Context, target string, port int) (ModbusProbeResult, error) {
	f.calls.Add(1)
	f.gotTarget = target
	f.gotPort = port
	return f.res, nil
}

func modbusFingerprintPayload(idemKey, targetKind, value string, findings []any, options map[string]any) map[string]any {
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

func TestModbusDispatch_Port502_InvokesProber(t *testing.T) {
	prober := &fakeModbusProber{res: ModbusProbeResult{
		VendorName: "Schneider Electric", ProductCode: "BMENOC0301",
		MajorMinorRevision: "2.10", FunctionCode: 0x2B,
		IsModbus: true, Outcome: "success",
	}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{ModbusProber: prober})

	job := goodjob.Job{ID: "x", Params: modbusFingerprintPayload(
		"sf-modbus-1", "host", "plc.example.fr",
		[]any{map[string]any{"port": float64(502)}}, nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Fatalf("expected 1 probe call, got %d", prober.calls.Load())
	}
	if prober.gotPort != 502 {
		t.Errorf("expected port=502, got %d", prober.gotPort)
	}

	all, _ := store.List(context.Background())
	var got ModbusProbeResult
	if err := json.Unmarshal([]byte(all[0].Status), &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.VendorName != "Schneider Electric" {
		t.Errorf("vendor: got %q", got.VendorName)
	}
}

func TestModbusDispatch_OptionsProtocols(t *testing.T) {
	prober := &fakeModbusProber{res: ModbusProbeResult{Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{ModbusProber: prober})

	job := goodjob.Job{ID: "x", Params: modbusFingerprintPayload(
		"sf-modbus-2", "ip", "192.0.2.10", nil,
		map[string]any{"protocols": []any{"modbus"}},
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Fatalf("expected 1 probe call via options.protocols=modbus, got %d", prober.calls.Load())
	}
}

func TestModbusDispatch_OtherPort_NoProbe(t *testing.T) {
	prober := &fakeModbusProber{}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{ModbusProber: prober})

	job := goodjob.Job{ID: "x", Params: modbusFingerprintPayload(
		"sf-modbus-3", "host", "h.example.fr",
		[]any{map[string]any{"port": float64(80)}}, nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 0 {
		t.Fatalf("expected 0 probe calls, got %d", prober.calls.Load())
	}
}

func TestModbusDispatch_NilProber_PersistsSkipped(t *testing.T) {
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{}) // pas de ModbusProber

	job := goodjob.Job{ID: "x", Params: modbusFingerprintPayload(
		"sf-modbus-4", "host", "h.example.fr",
		[]any{map[string]any{"port": float64(502)}}, nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	all, _ := store.List(context.Background())
	if !strings.Contains(all[0].Status, "skipped") {
		t.Errorf("expected status to mention skipped, got %q", all[0].Status)
	}
}

// TestModbusDispatch_FiveCohabits : SSH(22) + RDP(3389) + MQTT(1883) +
// CoAP(5683) + Modbus(502) doivent cohabiter sans interférence.
func TestModbusDispatch_FiveCohabits(t *testing.T) {
	sshProber := &fakeSSHProber{res: SSHProbeResult{Outcome: "success"}}
	rdpProber := &fakeRDPProber{res: RDPProbeResult{Outcome: "success"}}
	mqttProber := &fakeMQTTProber{res: MQTTProbeResult{Outcome: "success"}}
	coapProber := &fakeCoAPProber{res: CoAPProbeResult{Outcome: "success"}}
	modbusProber := &fakeModbusProber{res: ModbusProbeResult{Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{
		SSHProber: sshProber, RDPProber: rdpProber,
		MQTTProber: mqttProber, CoAPProber: coapProber,
		ModbusProber: modbusProber,
	})

	cases := []struct {
		key                            string
		port                           float64
		ssh, rdp, mqtt, coap, modbus   int64
	}{
		{"key-22-ssh", 22, 1, 0, 0, 0, 0},
		{"key-3389-rdp", 3389, 1, 1, 0, 0, 0},
		{"key-1883-mqtt", 1883, 1, 1, 1, 0, 0},
		{"key-5683-coap", 5683, 1, 1, 1, 1, 0},
		{"key-502-modbus", 502, 1, 1, 1, 1, 1},
	}
	for _, c := range cases {
		job := goodjob.Job{ID: c.key, Params: modbusFingerprintPayload(
			c.key, "host", "h.example.fr",
			[]any{map[string]any{"port": c.port}}, nil,
		)}
		if err := handler(context.Background(), job); err != nil {
			t.Fatalf("handler[%s]: %v", c.key, err)
		}
		got := []int64{
			sshProber.calls.Load(), rdpProber.calls.Load(),
			mqttProber.calls.Load(), coapProber.calls.Load(),
			modbusProber.calls.Load(),
		}
		want := []int64{c.ssh, c.rdp, c.mqtt, c.coap, c.modbus}
		for i := range got {
			if got[i] != want[i] {
				t.Fatalf("port %v: got %v, want %v", c.port, got, want)
			}
		}
	}
}
