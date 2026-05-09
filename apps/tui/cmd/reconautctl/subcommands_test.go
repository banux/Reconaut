// SPDX-License-Identifier: AGPL-3.0-only
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/banux/Reconaut/apps/tui/internal/mcp"
)

// Cf. openspec/changes/mcp-as-primary-entrypoint/tasks.md §3.2 :
// "capturer l'URL appelée, vérifier qu'elle est sous /mcp/* (sauf
// login qui appelle /auth/sessions puis /auth/api_keys)."

type recordingServer struct {
	mu   sync.Mutex
	urls []string
}

func (r *recordingServer) record(req *http.Request) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.urls = append(r.urls, req.URL.Path)
}

func (r *recordingServer) snapshot() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, len(r.urls))
	copy(out, r.urls)
	return out
}

func newServer(t *testing.T, rec *recordingServer) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, req *http.Request) {
		rec.record(req)

		switch {
		case req.URL.Path == "/auth/sessions":
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(201)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"user":    map[string]any{"id": "u1"},
				"api_key": map[string]any{"secret": "k_secret"},
			})
		case strings.HasPrefix(req.URL.Path, "/mcp/tools/"):
			tool := strings.TrimPrefix(req.URL.Path, "/mcp/tools/")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(200)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"tool":   tool,
				"result": map[string]any{"ok": true, "scan_id": "s1"},
			})
		default:
			w.WriteHeader(404)
		}
	})
	return httptest.NewServer(mux)
}

func TestSubcommands_AllUseMCPExceptLogin(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir()) // isole le stockage des credentials

	rec := &recordingServer{}
	srv := newServer(t, rec)
	defer srv.Close()

	c := mcp.New(srv.URL, "test")
	var buf bytes.Buffer
	ctx := context.Background()

	// scope list -> /mcp/tools/list_scopes
	if err := runScopeList(ctx, c, &buf); err != nil {
		t.Fatalf("scope list: %v", err)
	}
	// scope add -> /mcp/tools/add_scope
	if err := runScopeAdd(ctx, c, &buf, "ip", "192.0.2.1"); err != nil {
		t.Fatalf("scope add: %v", err)
	}
	// scan request -> /mcp/tools/request_scan
	if err := runScanRequest(ctx, c, &buf, "tcp_probe", "ip", "192.0.2.1"); err != nil {
		t.Fatalf("scan request: %v", err)
	}
	// scan list -> /mcp/tools/list_scans
	if err := runScanList(ctx, c, &buf); err != nil {
		t.Fatalf("scan list: %v", err)
	}
	// hosts search -> /mcp/tools/search_hosts
	if err := runHostsSearch(ctx, c, &buf, "x", 0); err != nil {
		t.Fatalf("hosts search: %v", err)
	}
	// doctor -> /mcp/tools/system_doctor
	if err := runDoctor(ctx, c, &buf); err != nil {
		t.Fatalf("doctor: %v", err)
	}

	// login parle REST
	if _, err := runLogin(ctx, srv.URL, "secret", &buf, nil); err != nil {
		t.Fatalf("login: %v", err)
	}

	urls := rec.snapshot()
	if len(urls) == 0 {
		t.Fatal("no URLs recorded")
	}

	for _, u := range urls {
		if !(strings.HasPrefix(u, "/mcp/") || u == "/auth/sessions" || u == "/auth/api_keys" || u == "/healthz") {
			t.Errorf("unexpected URL %q : doit être /mcp/* ou /auth/* ou /healthz", u)
		}
	}

	// Vérifie que les commandes métier ont bien tapé /mcp/*.
	mcpURLs := 0
	for _, u := range urls {
		if strings.HasPrefix(u, "/mcp/") {
			mcpURLs++
		}
	}
	if mcpURLs < 6 {
		t.Errorf("expected at least 6 MCP calls, got %d (urls=%v)", mcpURLs, urls)
	}

	// Vérifie présence de /auth/sessions dans les urls (login).
	hasAuth := false
	for _, u := range urls {
		if u == "/auth/sessions" {
			hasAuth = true
		}
	}
	if !hasAuth {
		t.Error("login did not hit /auth/sessions")
	}
}

func TestAgentChat_UsesMCPStreaming(t *testing.T) {
	rec := &recordingServer{}
	mux := http.NewServeMux()
	mux.HandleFunc("/mcp/tools/agent_chat", func(w http.ResponseWriter, req *http.Request) {
		rec.record(req)
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		flusher, _ := w.(http.Flusher)
		for _, t := range []string{"start", "row", "done"} {
			payload := map[string]any{
				"tool":    "agent_chat",
				"partial": t != "done",
				"result":  map[string]any{"type": t},
			}
			b, _ := json.Marshal(payload)
			_, _ = w.Write([]byte("event: tool_result\ndata: "))
			_, _ = w.Write(b)
			_, _ = w.Write([]byte("\n\n"))
			flusher.Flush()
		}
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	c := mcp.New(srv.URL, "test")
	var buf bytes.Buffer
	if err := runAgentChat(context.Background(), c, &buf, "modbus"); err != nil {
		t.Fatalf("runAgentChat: %v", err)
	}

	urls := rec.snapshot()
	if len(urls) != 1 || urls[0] != "/mcp/tools/agent_chat" {
		t.Errorf("expected single /mcp/tools/agent_chat call, got %v", urls)
	}
	if !strings.Contains(buf.String(), "[start]") {
		t.Errorf("expected start chunk in output: %s", buf.String())
	}
	if !strings.Contains(buf.String(), "[done]") {
		t.Errorf("expected done chunk in output: %s", buf.String())
	}
}
