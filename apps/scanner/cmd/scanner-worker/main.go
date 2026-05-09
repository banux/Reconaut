// SPDX-License-Identifier: AGPL-3.0-only
// Package main is the entrypoint for the scanner-worker binary.
//
// Spec source: openspec/changes/add-tech-stack/specs/architecture/spec.md
// (workers Go autonomes consomment good_jobs via SELECT ... FOR UPDATE
// SKIP LOCKED, pas de broker externe).
// openspec/changes/add-tech-stack/tasks.md §5.1.
//
// Le binaire :
//  1. lit la chaîne de connexion Postgres dans `RECONAUT_DATABASE_URL`
//     (ou se met en mode `--dry-run` si la variable est absente, utile
//     pour les checks `go build` et `bin/doctor`),
//  2. ouvre une connexion `database/sql` (le driver pgx ou lib/pq doit
//     être enregistré par un import side-effect quand on linke le
//     binaire en prod — voir `_ "github.com/jackc/pgx/v5/stdlib"`
//     activé par tag `pg`),
//  3. lance `goodjob.Loop` avec un handler `scanhandler.New` qui valide
//     le payload `ScanJobV1` puis persiste un résultat avec
//     dédoublonnage par `idempotency_key`,
//  4. en cas de panic dans le handler, `worker.SafeRun` capture, le job
//     est marqué `error` côté `good_jobs`, le compteur Prometheus est
//     incrémenté, et la boucle continue (cf. §5.2).
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/goodjob"
	"github.com/banux/Reconaut/apps/scanner/internal/results"
	"github.com/banux/Reconaut/apps/scanner/internal/scanhandler"
	"github.com/banux/Reconaut/apps/scanner/internal/worker"
)

func main() {
	var (
		queue       string
		idleBackoff time.Duration
		showVersion bool
		dryRun      bool
	)
	flag.StringVar(&queue, "queue", envOr("RECONAUT_QUEUE", "scan"), "GoodJob queue name to consume")
	flag.DurationVar(&idleBackoff, "idle-backoff", time.Second, "sleep duration when the queue is empty")
	flag.BoolVar(&showVersion, "version", false, "print the worker version and exit")
	flag.BoolVar(&dryRun, "dry-run", false, "boot without DB (in-memory job/results stores) — useful for smoke tests")
	flag.Parse()

	if showVersion {
		fmt.Printf("scanner-worker %s\n", worker.Version)
		os.Exit(0)
	}

	dbURL := os.Getenv("RECONAUT_DATABASE_URL")
	if dbURL == "" && !dryRun {
		fmt.Fprintln(os.Stderr, "RECONAUT_DATABASE_URL not set ; pass --dry-run to boot without a DB.")
		os.Exit(64) // EX_USAGE
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	jobStore, resStore, closeFn, err := wireStores(dbURL, dryRun)
	if err != nil {
		log.Fatalf("scanner-worker: wire stores: %v", err)
	}
	defer closeFn()

	handler := scanhandler.New(resStore, time.Now)

	log.Printf("scanner-worker %s started (queue=%s, dry-run=%v)", worker.Version, queue, dryRun)
	processed, loopErr := goodjob.Loop(ctx, jobStore, handler, goodjob.LoopConfig{
		Queue:        queue,
		IdleBackoff:  idleBackoff,
		PanicCounter: worker.NewNoopCounter(),
	})
	log.Printf("scanner-worker shutting down (processed=%d, err=%v)", processed, loopErr)
	if loopErr != nil {
		os.Exit(1)
	}
}

// wireStores returns the goodjob.Store and results.Store the worker
// loop will use, plus a deferred-close func. In dry-run mode both are
// in-memory ; in normal mode the goodjob.Store is SQL-backed and the
// results.Store will be too once init-reconaut-platform §2.1 lands the
// Postgres results table (in the meantime the in-memory store keeps
// the binary bootable end-to-end against a real `good_jobs` table).
func wireStores(dbURL string, dryRun bool) (goodjob.Store, results.Store, func(), error) {
	if dryRun {
		return goodjob.NewInMemoryStore(), results.NewInMemoryStore(), func() {}, nil
	}
	// Production wiring : open a *sql.DB. The driver registration is
	// expected to happen via build tag (e.g. cmd/scanner-worker/db_pgx.go
	// imports `_ "github.com/jackc/pgx/v5/stdlib"`). When init-reconaut-platform
	// lands, this branch will also wire a SQL-backed results.Store.
	db, err := openDB(dbURL)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("open db: %w", err)
	}
	return goodjob.NewSQLStore(db), results.NewInMemoryStore(), func() { _ = db.Close() }, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
