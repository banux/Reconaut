// SPDX-License-Identifier: AGPL-3.0-only
package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Cf. openspec/changes/add-http-probe/tasks.md §2.2.

func TestHTTPAdapter_DefaultsAndOverridesApplied(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Server", "fake/1.0")
		_, _ = w.Write([]byte("ok"))
	}))
	defer srv.Close()

	host, port := splitHostPort(t, strings.TrimPrefix(srv.URL, "http://"))

	adapter := httpAdapter{}
	adapter.cfg.Timeout = 1 * time.Second
	adapter.cfg.MaxBodyBytes = 16 * 1024

	res, err := adapter.Probe(context.Background(), host, port, "http")
	if err != nil {
		t.Fatalf("adapter.Probe: %v", err)
	}
	if res.Outcome != "success" {
		t.Errorf("expected outcome=success, got %q", res.Outcome)
	}
	if res.Status != 200 {
		t.Errorf("expected status=200, got %d", res.Status)
	}
	if res.Server != "fake/1.0" {
		t.Errorf("expected server=fake/1.0, got %q", res.Server)
	}
}

func TestHTTPAdapter_RespectsTimeout(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	// Accept silencieux : ne renvoie jamais.
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		buf := make([]byte, 1)
		_, _ = c.Read(buf)
	}()

	host, port := splitHostPort(t, ln.Addr().String())
	adapter := httpAdapter{}
	adapter.cfg.Timeout = 300 * time.Millisecond
	adapter.cfg.MaxBodyBytes = 1024

	start := time.Now()
	res, err := adapter.Probe(context.Background(), host, port, "http")
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("adapter.Probe: %v", err)
	}
	if elapsed > 2*time.Second {
		t.Errorf("probe took %v, expected ~300ms", elapsed)
	}
	if res.Outcome == "success" {
		t.Errorf("expected non-success outcome, got %q", res.Outcome)
	}
}

func splitHostPort(t *testing.T, addr string) (string, int) {
	t.Helper()
	h, p, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatalf("split %q: %v", addr, err)
	}
	n, err := strconv.Atoi(p)
	if err != nil {
		t.Fatalf("atoi %q: %v", p, err)
	}
	return h, n
}
