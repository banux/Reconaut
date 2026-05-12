// SPDX-License-Identifier: AGPL-3.0-only
package runtime

import (
	"context"
	"database/sql"
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

// TestPgxDriverRegistered : le blank import enregistre bien "pgx"
// auprès de database/sql. C'est l'invariant central — sans lui le
// sql.Open échoue silencieusement (lazy) puis le Ping retourne une
// erreur cryptique.
//
// Cf. openspec/changes/add-scanner-pgx-driver/specs/scanning/spec.md
//   -> Requirement: Postgres-Backed Scanner Stores
func TestPgxDriverRegistered(t *testing.T) {
	found := false
	for _, d := range sql.Drivers() {
		if d == "pgx" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("pgx driver not registered ; sql.Drivers()=%v", sql.Drivers())
	}
}

// TestWireStores_DryRun : retourne les in-memory stores sans toucher
// la DB. Le closeFn est un no-op.
func TestWireStores_DryRun(t *testing.T) {
	js, rs, closeFn, err := wireStores(Config{}, "", true)
	if err != nil {
		t.Fatalf("wireStores: %v", err)
	}
	if _, ok := js.(*goodjob.InMemoryStore); !ok {
		t.Errorf("expected *goodjob.InMemoryStore, got %T", js)
	}
	if _, ok := rs.(*results.InMemoryStore); !ok {
		t.Errorf("expected *results.InMemoryStore, got %T", rs)
	}
	// closeFn must not panic.
	closeFn()
}

// TestWireStores_BadURLFailsFast : avec un URL pointant vers un port
// fermé, la connexion sql.Open est lazy mais le Ping doit échouer
// dans le timeout strict (≤ 2 s) avec un message qui mentionne "db ping".
func TestWireStores_BadURLFailsFast(t *testing.T) {
	url := "postgres://reconaut:nope@127.0.0.1:65534/reconaut_test?sslmode=disable"
	start := time.Now()
	js, rs, closeFn, err := wireStores(Config{}, url, false)
	elapsed := time.Since(start)

	if err == nil {
		// closeFn n'est utile que sur le chemin succès
		if closeFn != nil {
			closeFn()
		}
		t.Fatalf("expected error on unreachable DB, got js=%v rs=%v", js, rs)
	}
	if !strings.Contains(err.Error(), "db ping") {
		t.Errorf("error should mention 'db ping', got %q", err.Error())
	}
	if elapsed > 3*time.Second {
		t.Errorf("fail-fast violated: took %v (expected ≤ 2s + slack)", elapsed)
	}
}

// TestWireStores_NoDriverLinkedMessageGone : on s'assure que l'ancien
// message historique cryptique n'est plus jamais émis. Si quelqu'un
// retire le blank import, la query echouera avec "unknown driver"
// plutôt qu'avec "no DB driver linked".
func TestWireStores_NoDriverLinkedMessageGone(t *testing.T) {
	url := "postgres://reconaut:nope@127.0.0.1:65534/db?sslmode=disable"
	_, _, _, err := wireStores(Config{}, url, false)
	if err == nil {
		t.Fatal("expected error")
	}
	if strings.Contains(err.Error(), "no DB driver linked") {
		t.Errorf("legacy message survived : %q", err.Error())
	}
}
