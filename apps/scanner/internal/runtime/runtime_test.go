package runtime

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/goodjob"
	"github.com/banux/Reconaut/apps/scanner/internal/results"
)

// Cf. openspec/changes/replace-web-with-tui/tasks.md §3.1 :
// chaque binaire scanner-<kind> consomme la queue `scan:<kind>` et
// délègue le no-op au scanhandler partagé.

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

func TestRun_ConsumesQueueScopedByKind(t *testing.T) {
	jobStore := goodjob.NewInMemoryStore()
	resStore := results.NewInMemoryStore()

	// Enqueue un job sur la queue spécialisée tls_capture et un autre
	// sur tcp_probe ; le binaire tls_capture ne doit consommer QUE le
	// premier.
	tlsParams := map[string]any{
		"schema_version":  float64(1),
		"idempotency_key": "scan-tls-001-abc",
		"scan_kind":       "tls_capture",
		"target":          map[string]any{"kind": "ip", "value": "192.0.2.1"},
		"requested_at":    time.Now().UTC().Format(time.RFC3339),
	}
	tcpParams := map[string]any{
		"schema_version":  float64(1),
		"idempotency_key": "scan-tcp-001-def",
		"scan_kind":       "tcp_probe",
		"target":          map[string]any{"kind": "ip", "value": "192.0.2.2"},
		"requested_at":    time.Now().UTC().Format(time.RFC3339),
	}
	jobStore.Enqueue("j-tls", "j-tls", "scan:tls_capture", tlsParams)
	jobStore.Enqueue("j-tcp", "j-tcp", "scan:tcp_probe", tcpParams)

	// On veut un test rapide : le runtime tourne dans une goroutine,
	// on laisse le temps de claim+process le job tls_capture, puis on
	// arrête.
	done := make(chan int, 1)
	go func() {
		done <- Run(Config{
			ScanKind:    "tls_capture",
			JobStore:    jobStore,
			ResultStore: resStore,
			IdleBackoff: 1 * time.Millisecond,
			Args:        []string{},
		})
	}()

	// Wait until the tls job is consumed (resStore has 1 result), then
	// signal shutdown via SIGTERM-equivalent (we cancel ctx through
	// a fresh sigint, but here we just rely on poll + a short timeout).
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if resStore.Count() >= 1 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	if resStore.Count() != 1 {
		t.Fatalf("expected 1 result (tls only), got %d", resStore.Count())
	}
	persisted, _ := resStore.List(context.Background())
	if persisted[0].ScanKind != "tls_capture" {
		t.Errorf("persisted result.ScanKind = %q, want tls_capture", persisted[0].ScanKind)
	}

	// Vérifie que le job tcp_probe est resté en attente (pas consommé
	// par scanner-tls_capture).
	if jobStore.FinishedState("j-tcp") != "" {
		t.Errorf("tcp_probe job should NOT be claimed by tls_capture worker")
	}

	// Force shutdown: the inner ctx is bound to SIGINT/SIGTERM ; on
	// laisse le test finir et le `go func()` mourra à la fin du
	// process. Pour éviter des fuites, on drain `done` non bloquant.
	select {
	case <-done:
	case <-time.After(50 * time.Millisecond):
		// OK, le worker tourne toujours en idle ; ce n'est pas un
		// problème pour le test (il sera tué à la fin du process Go).
	}
	_ = strings.TrimSpace
}
