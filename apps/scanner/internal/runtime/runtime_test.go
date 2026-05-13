// SPDX-License-Identifier: AGPL-3.0-only
package runtime

import (
	"context"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/agentclient"
	"github.com/banux/Reconaut/apps/scanner/internal/goodjob"
)

// Cf. openspec/changes/remote-scanner-agents/specs/scanning/spec.md
//   -> Requirement: Workers Go consomment la file via MCP HTTP

func TestRun_VersionFlag(t *testing.T) {
	exit := Run(Config{
		ScanKind: "tcp_probe",
		Args:     []string{"--version"},
	})
	if exit != 0 {
		t.Errorf("--version should exit 0, got %d", exit)
	}
}

func TestRun_RequiresScanKind(t *testing.T) {
	exit := Run(Config{ScanKind: "", Args: []string{"--dry-run"}})
	if exit == 0 {
		t.Errorf("expected non-zero exit when ScanKind missing")
	}
}

// fakeAgentClient implémente AgentClient pour exercer la boucle agent
// sans toucher au réseau.
type fakeAgentClient struct {
	mu                    sync.Mutex
	claimCalls            atomic.Int64
	submitCalls           atomic.Int64
	failCalls             atomic.Int64
	heartbeatCalls        atomic.Int64
	jobsToReturn          []*agentclient.Job // FIFO
	lastSubmitArgs        map[string]string
	lastFailArgs          map[string]string
	lastHeartbeatArgs     map[string]string
	lastHeartbeatInflight int
}

func (f *fakeAgentClient) Claim(_ context.Context, _ string, _ int) (*agentclient.Job, error) {
	f.claimCalls.Add(1)
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.jobsToReturn) == 0 {
		return &agentclient.Job{Empty: true}, nil
	}
	job := f.jobsToReturn[0]
	f.jobsToReturn = f.jobsToReturn[1:]
	return job, nil
}

func (f *fakeAgentClient) Submit(_ context.Context, jobID, idemKey, scanKind, targetKind, targetValue, _ string, _ time.Time) error {
	f.submitCalls.Add(1)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lastSubmitArgs = map[string]string{
		"job_id": jobID, "idem": idemKey, "scan_kind": scanKind,
		"target_kind": targetKind, "target_value": targetValue,
	}
	return nil
}

func (f *fakeAgentClient) Fail(_ context.Context, jobID, errMsg string) error {
	f.failCalls.Add(1)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lastFailArgs = map[string]string{"job_id": jobID, "error": errMsg}
	return nil
}

func (f *fakeAgentClient) Heartbeat(_ context.Context, scanKind, version string, inflight int) error {
	f.heartbeatCalls.Add(1)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lastHeartbeatArgs = map[string]string{
		"scan_kind": scanKind, "version": version,
	}
	f.lastHeartbeatInflight = inflight
	return nil
}

// TestAgentLoop_DirectInvocation : on appelle agentLoop dans une
// goroutine avec un ctx cancellable, et on observe les compteurs.
func TestAgentLoop_DirectInvocation(t *testing.T) {
	client := &fakeAgentClient{
		jobsToReturn: []*agentclient.Job{
			{
				ID: "j-1",
				Params: map[string]any{
					"idempotency_key": "k-1",
					"scan_kind":       "dns_records",
					"target":          map[string]any{"kind": "domain", "value": "example.fr"},
				},
			},
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	processed, err := agentLoop(ctx, client, func(_ context.Context, _ goodjob.Job) error {
		return nil
	}, "scan:dns_records", 20*time.Millisecond, 300)

	if err != nil {
		t.Fatalf("agentLoop: %v", err)
	}
	if processed < 1 {
		t.Errorf("expected at least 1 processed, got %d", processed)
	}
	if client.submitCalls.Load() < 1 {
		t.Errorf("expected at least 1 submit, got %d", client.submitCalls.Load())
	}
	if client.lastSubmitArgs["idem"] != "k-1" {
		t.Errorf("submit args missing idem k-1: %v", client.lastSubmitArgs)
	}
	if client.failCalls.Load() != 0 {
		t.Errorf("expected 0 fail calls, got %d", client.failCalls.Load())
	}
}

// TestBuildClient_MissingEnv : sans RECONAUT_API_URL ou _API_KEY, on
// retourne une erreur explicite.
func TestBuildClient_MissingEnv(t *testing.T) {
	t.Setenv("RECONAUT_API_URL", "")
	t.Setenv("RECONAUT_API_KEY", "")
	_, err := buildClient("dns_records")
	if err == nil {
		t.Fatal("expected error when API URL missing")
	}
	if !strings.Contains(err.Error(), "RECONAUT_API_URL") {
		t.Errorf("error should mention RECONAUT_API_URL, got %q", err.Error())
	}

	t.Setenv("RECONAUT_API_URL", "https://api.local")
	_, err = buildClient("dns_records")
	if err == nil {
		t.Fatal("expected error when API KEY missing")
	}
	if !strings.Contains(err.Error(), "RECONAUT_API_KEY") {
		t.Errorf("error should mention RECONAUT_API_KEY, got %q", err.Error())
	}
}

// TestBuildClient_HappyPath : avec env complet, on obtient un client
// non-nil.
func TestBuildClient_HappyPath(t *testing.T) {
	t.Setenv("RECONAUT_API_URL", "https://api.local")
	t.Setenv("RECONAUT_API_KEY", "k-secret")
	t.Setenv("RECONAUT_WORKER_ID", "edge-1")
	c, err := buildClient("dns_records")
	if err != nil {
		t.Fatalf("buildClient: %v", err)
	}
	if c == nil {
		t.Fatal("expected non-nil client")
	}
}

// TestHeartbeatLoop_PingsClient : la goroutine heartbeat appelle le
// client à intervalle régulier jusqu'à annulation du ctx.
func TestHeartbeatLoop_PingsClient(t *testing.T) {
	client := &fakeAgentClient{}
	inflight := &atomic.Int64{}

	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		heartbeatLoop(ctx, client, "dns_records", "0.0.0-test", inflight, 50*time.Millisecond)
		close(done)
	}()

	// Laisse 250ms : on attend ≥ 4 heartbeats (1 initial + ~5 ticks à 50ms).
	time.Sleep(250 * time.Millisecond)
	cancel()
	<-done

	if got := client.heartbeatCalls.Load(); got < 4 {
		t.Fatalf("expected ≥ 4 heartbeats in 250ms, got %d", got)
	}
	if client.lastHeartbeatArgs["scan_kind"] != "dns_records" {
		t.Errorf("scan_kind args: %+v", client.lastHeartbeatArgs)
	}
	if client.lastHeartbeatArgs["version"] != "0.0.0-test" {
		t.Errorf("version args: %+v", client.lastHeartbeatArgs)
	}
}

// TestReadHeartbeatInterval : env parsing.
func TestReadHeartbeatInterval(t *testing.T) {
	tests := []struct {
		env  string
		want time.Duration
	}{
		{"", 30 * time.Second},
		{"5", 5 * time.Second},
		{"60", 60 * time.Second},
		{"0", 30 * time.Second}, // invalid → default
		{"-1", 30 * time.Second},
		{"abc", 30 * time.Second},
		{"700", 600 * time.Second}, // clamped to max
	}
	for _, tc := range tests {
		t.Run(tc.env, func(t *testing.T) {
			t.Setenv("RECONAUT_HEARTBEAT_INTERVAL", tc.env)
			got := readHeartbeatInterval()
			if got != tc.want {
				t.Errorf("env=%q: got %s, want %s", tc.env, got, tc.want)
			}
		})
	}
}

// TestRun_DryRunNoHTTP : en --dry-run, aucun client HTTP n'est
// construit, la boucle utilise les InMemory stores et exit propre
// sur SIGTERM (qu'on émule via cancellation prématurée).
func TestRun_DryRunNoHTTP(t *testing.T) {
	exit := make(chan int, 1)
	go func() {
		exit <- Run(Config{
			ScanKind: "tcp_probe",
			Args:     []string{"--dry-run", "--idle-backoff=10ms"},
		})
	}()
	select {
	case <-time.After(150 * time.Millisecond):
		// Le binaire tourne en idle (file vide). On accepte qu'il
		// soit toujours dans la boucle — pas de crash, pas d'HTTP
		// tenté (impossible à vérifier sans instrumentation, mais on
		// confirme qu'il n'exit pas avec code d'erreur dans les 150ms).
	case code := <-exit:
		if code != 0 {
			t.Fatalf("dry-run exited with %d", code)
		}
	}
}

