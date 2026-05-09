// SPDX-License-Identifier: AGPL-3.0-only
package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Cf. openspec/changes/mcp-as-primary-entrypoint/tasks.md §3.1.
// Test contre un serveur HTTP+SSE de test qui simule deux outils
// (echo, stream_echo) ; assert que Invoke retourne le bon résultat
// et que InvokeStreaming émet les chunks dans l'ordre.

func TestInvoke_Echo(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/mcp/tools/echo" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer test-key" {
			t.Errorf("missing/wrong Authorization header: %q", r.Header.Get("Authorization"))
		}
		var params map[string]any
		_ = json.NewDecoder(r.Body).Decode(&params)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"tool":   "echo",
			"result": map[string]any{"echoed": params["msg"]},
		})
	}))
	defer srv.Close()

	c := New(srv.URL, "test-key")
	res, err := c.Invoke(context.Background(), "echo", map[string]any{"msg": "hello"})
	if err != nil {
		t.Fatalf("Invoke error: %v", err)
	}
	if res.Tool != "echo" {
		t.Errorf("Tool=%q want echo", res.Tool)
	}
	if got := res.Result["echoed"]; got != "hello" {
		t.Errorf("echoed=%v want hello", got)
	}
}

func TestInvoke_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(403)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"error":   "rbac_forbidden",
			"message": "missing scopes: write:scopes",
		})
	}))
	defer srv.Close()

	c := New(srv.URL, "k")
	res, err := c.Invoke(context.Background(), "add_scope", map[string]any{"kind": "ip", "value": "192.0.2.1"})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if res.Error != "rbac_forbidden" {
		t.Errorf("error code=%q want rbac_forbidden", res.Error)
	}
	if !strings.Contains(res.Message, "write:scopes") {
		t.Errorf("message %q should name write:scopes", res.Message)
	}
}

func TestInvokeStreaming_StreamEcho(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/mcp/tools/stream_echo" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if r.Header.Get("Accept") != "text/event-stream" {
			t.Errorf("missing Accept: text/event-stream, got %q", r.Header.Get("Accept"))
		}

		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		flusher, _ := w.(http.Flusher)

		for i := 1; i <= 3; i++ {
			payload := map[string]any{
				"tool":    "stream_echo",
				"partial": i < 3,
				"result":  map[string]any{"index": i},
			}
			b, _ := json.Marshal(payload)
			fmt.Fprintf(w, "event: tool_result\ndata: %s\n\n", b)
			flusher.Flush()
		}
	}))
	defer srv.Close()

	c := New(srv.URL, "test-key")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	ch, err := c.InvokeStreaming(ctx, "stream_echo", map[string]any{})
	if err != nil {
		t.Fatalf("InvokeStreaming error: %v", err)
	}

	var got []int
	for chunk := range ch {
		idx, _ := chunk.Result["index"].(float64)
		got = append(got, int(idx))
	}
	if len(got) != 3 {
		t.Fatalf("expected 3 chunks, got %d (%v)", len(got), got)
	}
	for i, v := range got {
		if v != i+1 {
			t.Errorf("chunk[%d]=%d want %d", i, v, i+1)
		}
	}
}

func TestInvoke_RequiresToolName(t *testing.T) {
	c := New("http://example.test", "k")
	_, err := c.Invoke(context.Background(), "", nil)
	if err == nil {
		t.Fatal("expected error for empty tool name")
	}
}
