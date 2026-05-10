// SPDX-License-Identifier: AGPL-3.0-only
package scanhandler

import (
	"context"
	"encoding/json"
	"sync/atomic"
	"testing"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/goodjob"
	"github.com/banux/Reconaut/apps/scanner/internal/results"
)

// Cf. openspec/changes/add-http-probe/tasks.md §2.1.

type fakeHTTPProber struct {
	calls     atomic.Int64
	gotTarget string
	gotPort   int
	gotScheme string
	res       HTTPProbeResult
}

func (f *fakeHTTPProber) Probe(_ context.Context, target string, port int, scheme string) (HTTPProbeResult, error) {
	f.calls.Add(1)
	f.gotTarget = target
	f.gotPort = port
	f.gotScheme = scheme
	return f.res, nil
}

func httpBannerPayload(idemKey, targetKind, value string, findings []any, options map[string]any) map[string]any {
	out := map[string]any{
		"schema_version":  float64(1),
		"idempotency_key": idemKey,
		"scan_kind":       "http_banner",
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

func TestHTTPDispatch_Port80_DefaultsToHTTPScheme(t *testing.T) {
	prober := &fakeHTTPProber{res: HTTPProbeResult{Status: 200, Outcome: "success"}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{HTTPProber: prober})

	job := goodjob.Job{ID: "j1", Params: httpBannerPayload(
		"hb-0001xxx", "host", "example.fr",
		[]any{map[string]any{"port": float64(80)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.calls.Load() != 1 {
		t.Fatalf("expected 1 probe call, got %d", prober.calls.Load())
	}
	if prober.gotScheme != "http" {
		t.Errorf("expected scheme=http, got %q", prober.gotScheme)
	}
	if prober.gotPort != 80 {
		t.Errorf("expected port=80, got %d", prober.gotPort)
	}
}

func TestHTTPDispatch_Port443_DefaultsToHTTPSScheme(t *testing.T) {
	prober := &fakeHTTPProber{res: HTTPProbeResult{Status: 200}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{HTTPProber: prober})

	job := goodjob.Job{ID: "j2", Params: httpBannerPayload(
		"hb-0002xxx", "host", "example.fr",
		[]any{map[string]any{"port": float64(443)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.gotScheme != "https" {
		t.Errorf("expected scheme=https on port 443, got %q", prober.gotScheme)
	}
	if prober.gotPort != 443 {
		t.Errorf("expected port=443, got %d", prober.gotPort)
	}
}

func TestHTTPDispatch_TLSFlagInFindings_PromotesToHTTPS(t *testing.T) {
	prober := &fakeHTTPProber{res: HTTPProbeResult{Status: 200}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{HTTPProber: prober})

	job := goodjob.Job{ID: "j3", Params: httpBannerPayload(
		"hb-0003xxx", "host", "example.fr",
		[]any{map[string]any{"port": float64(8443), "tls": true}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.gotScheme != "https" {
		t.Errorf("expected scheme=https from tls flag, got %q", prober.gotScheme)
	}
	if prober.gotPort != 8443 {
		t.Errorf("expected port=8443, got %d", prober.gotPort)
	}
}

func TestHTTPDispatch_OptionsProtocolHTTPS(t *testing.T) {
	prober := &fakeHTTPProber{res: HTTPProbeResult{Status: 200}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{HTTPProber: prober})

	job := goodjob.Job{ID: "j4", Params: httpBannerPayload(
		"hb-0004xxx", "ip", "192.0.2.10",
		nil,
		map[string]any{"protocols": []any{"https"}},
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if prober.gotScheme != "https" {
		t.Errorf("expected scheme=https from options.protocols, got %q", prober.gotScheme)
	}
}

func TestHTTPDispatch_PersistsResultAsJSON(t *testing.T) {
	prober := &fakeHTTPProber{res: HTTPProbeResult{
		Scheme: "http", Status: 200, Server: "nginx/1.18.0",
		Outcome: "success", BodyExcerpt: "<html>hello</html>",
	}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{HTTPProber: prober})

	job := goodjob.Job{ID: "j5", Params: httpBannerPayload(
		"hb-0005xxx", "host", "example.fr",
		[]any{map[string]any{"port": float64(80)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	all, _ := store.List(context.Background())
	if len(all) != 1 {
		t.Fatalf("expected 1 stored result, got %d", len(all))
	}
	var got HTTPProbeResult
	if err := json.Unmarshal([]byte(all[0].Status), &got); err != nil {
		t.Fatalf("unmarshal: %v (raw=%q)", err, all[0].Status)
	}
	if got.Server != "nginx/1.18.0" {
		t.Errorf("expected server=nginx/1.18.0, got %q", got.Server)
	}
	if got.Status != 200 {
		t.Errorf("expected status=200, got %d", got.Status)
	}
}

func TestHTTPDispatch_NilProberPersistsSkipped(t *testing.T) {
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{}) // pas de HTTPProber

	job := goodjob.Job{ID: "j6", Params: httpBannerPayload(
		"hb-0006xxx", "host", "example.fr",
		[]any{map[string]any{"port": float64(80)}},
		nil,
	)}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	if store.Count() != 1 {
		t.Fatalf("expected 1 stored result, got %d", store.Count())
	}
}
