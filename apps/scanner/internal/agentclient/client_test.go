// SPDX-License-Identifier: AGPL-3.0-only
package agentclient

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeRailsServer simule le serveur Rails MCP : capture les requêtes
// et retourne des fixtures scriptées par toolName.
type fakeRailsServer struct {
	*httptest.Server
	mu       *sync.Mutex
	requests []recordedRequest
	handlers map[string]http.HandlerFunc
}

type recordedRequest struct {
	Tool       string
	Body       map[string]any
	AuthHeader string
}

func newFakeRails(t *testing.T) *fakeRailsServer {
	t.Helper()
	srv := &fakeRailsServer{
		mu:       &sync.Mutex{},
		handlers: map[string]http.HandlerFunc{},
	}
	srv.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// extract tool name from /mcp/tools/<name>
		path := strings.TrimPrefix(r.URL.Path, "/mcp/tools/")
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(raw, &body)
		srv.mu.Lock()
		srv.requests = append(srv.requests, recordedRequest{
			Tool: path, Body: body, AuthHeader: r.Header.Get("Authorization"),
		})
		srv.mu.Unlock()
		if h, ok := srv.handlers[path]; ok {
			h(w, r)
			return
		}
		http.Error(w, "no handler for "+path, http.StatusNotFound)
	}))
	return srv
}

func (s *fakeRailsServer) on(tool string, response map[string]any, status int) {
	s.handlers[tool] = func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"tool":   tool,
			"result": response,
		})
	}
}

func (s *fakeRailsServer) recorded() []recordedRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]recordedRequest, len(s.requests))
	copy(out, s.requests)
	return out
}

// ----------------- TESTS -----------------

func TestClaim_JobAvailable(t *testing.T) {
	srv := newFakeRails(t)
	defer srv.Close()
	srv.on("claim_scan_job", map[string]any{
		"empty": false,
		"job": map[string]any{
			"id":          "j-1",
			"params":      map[string]any{"scan_kind": "dns_records", "target": map[string]any{"kind": "domain", "value": "example.fr"}},
			"lease_until": "2026-05-13T12:05:00Z",
		},
	}, 200)

	c := New(srv.URL, "k-abc", "w-test", false)
	job, err := c.Claim(context.Background(), "scan:dns_records", 300)
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	if job.Empty {
		t.Fatal("expected Empty=false")
	}
	if job.ID != "j-1" {
		t.Errorf("ID: got %q want j-1", job.ID)
	}
	wantLease := time.Date(2026, 5, 13, 12, 5, 0, 0, time.UTC)
	if !job.LeaseUntil.Equal(wantLease) {
		t.Errorf("LeaseUntil: got %v want %v", job.LeaseUntil, wantLease)
	}

	reqs := srv.recorded()
	if len(reqs) != 1 || reqs[0].Tool != "claim_scan_job" {
		t.Fatalf("recorded reqs unexpected: %+v", reqs)
	}
	if reqs[0].AuthHeader != "Bearer k-abc" {
		t.Errorf("Authorization header: got %q want Bearer k-abc", reqs[0].AuthHeader)
	}
	if reqs[0].Body["worker_id"] != "w-test" {
		t.Errorf("worker_id missing in body: %+v", reqs[0].Body)
	}
}

func TestClaim_Empty(t *testing.T) {
	srv := newFakeRails(t)
	defer srv.Close()
	srv.on("claim_scan_job", map[string]any{"empty": true}, 200)

	c := New(srv.URL, "k", "w", false)
	job, err := c.Claim(context.Background(), "scan:x", 300)
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	if !job.Empty {
		t.Fatal("expected Empty=true")
	}
}

func TestSubmit_OK(t *testing.T) {
	srv := newFakeRails(t)
	defer srv.Close()
	srv.on("submit_scan_result", map[string]any{"ok": true}, 200)

	c := New(srv.URL, "k", "w", false)
	err := c.Submit(context.Background(), "j-1", "idem-1", "dns_records", "domain", "example.fr", "ok", time.Now())
	if err != nil {
		t.Fatalf("Submit: %v", err)
	}
	reqs := srv.recorded()
	if reqs[0].Body["idempotency_key"] != "idem-1" {
		t.Errorf("idempotency_key: %v", reqs[0].Body)
	}
}

func TestSubmit_BadRequest(t *testing.T) {
	srv := newFakeRails(t)
	defer srv.Close()
	srv.on("submit_scan_result", map[string]any{"ok": false, "error": "idempotency_key required"}, 200)

	c := New(srv.URL, "k", "w", false)
	err := c.Submit(context.Background(), "j", "", "k", "t", "v", "s", time.Now())
	if err == nil {
		t.Fatal("expected error on ok:false")
	}
	if !strings.Contains(err.Error(), "idempotency_key required") {
		t.Errorf("error msg: %v", err)
	}
}

func TestSubmit_HTTPError(t *testing.T) {
	srv := newFakeRails(t)
	defer srv.Close()
	srv.handlers["submit_scan_result"] = func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "internal", http.StatusInternalServerError)
	}

	c := New(srv.URL, "k", "w", false)
	err := c.Submit(context.Background(), "j", "i", "k", "t", "v", "s", time.Now())
	if err == nil {
		t.Fatal("expected error on 500")
	}
}

func TestFail_OK(t *testing.T) {
	srv := newFakeRails(t)
	defer srv.Close()
	srv.on("fail_scan_job", map[string]any{"ok": true}, 200)

	c := New(srv.URL, "k", "w", false)
	if err := c.Fail(context.Background(), "j-2", "boom"); err != nil {
		t.Fatalf("Fail: %v", err)
	}
	reqs := srv.recorded()
	if reqs[0].Body["error"] != "boom" {
		t.Errorf("error in body: %v", reqs[0].Body)
	}
}

func TestAuthHeader_BearerInjected(t *testing.T) {
	srv := newFakeRails(t)
	defer srv.Close()
	srv.on("claim_scan_job", map[string]any{"empty": true}, 200)

	c := New(srv.URL, "secret-token", "w", false)
	_, _ = c.Claim(context.Background(), "scan:x", 300)
	reqs := srv.recorded()
	if reqs[0].AuthHeader != "Bearer secret-token" {
		t.Errorf("got auth %q, want Bearer secret-token", reqs[0].AuthHeader)
	}
}

func TestNoAuthHeader_WhenAPIKeyEmpty(t *testing.T) {
	srv := newFakeRails(t)
	defer srv.Close()
	srv.on("claim_scan_job", map[string]any{"empty": true}, 200)

	c := New(srv.URL, "", "w", false)
	_, _ = c.Claim(context.Background(), "scan:x", 300)
	reqs := srv.recorded()
	if reqs[0].AuthHeader != "" {
		t.Errorf("got auth %q, want empty (no key)", reqs[0].AuthHeader)
	}
}
