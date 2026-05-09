// SPDX-License-Identifier: AGPL-3.0-only
// Package runtime assemble la boucle goodjob + le handler scan +
// l'ouverture de la connexion DB. Un binaire scanner-<kind> appelle
// `runtime.Run(scanKind)` et c'est tout.
//
// Source de vérité :
//
//	openspec/changes/replace-web-with-tui/tasks.md §3.1 :
//	  "Pour chaque scan_kind listé dans ScanJobV1, créer
//	   apps/scanner-<kind>/cmd/scanner-<kind>/main.go. Chaque main
//	   importe internal/goodjob + internal/jobschema + uniquement les
//	   sondeurs de son protocole. Le queue_name consommé est
//	   scan:<kind> (constante par binaire)."
//
// La factorisation isole le câblage commun ; chaque binaire reste
// libre d'importer en plus son sondeur dédié au moment où les changes
// `scan-engine-<protocol>` les livreront.
package runtime

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

// Config paramètre la boucle. Chaque binaire fournit un Config.
type Config struct {
	// ScanKind pilote le QueueName consommé : "scan:<kind>".
	ScanKind string
	// JobStore est injectable pour les tests ; nil → SQLStore depuis
	// `RECONAUT_DATABASE_URL`.
	JobStore goodjob.Store
	// ResultStore idem ; nil → InMemoryStore.
	ResultStore results.Store
	// IdleBackoff : sleep quand la file est vide.
	IdleBackoff time.Duration
	// Args : os.Args[1:] (utile pour les tests qui veulent forcer --dry-run).
	Args []string
	// HandlerOptions : options injectables pour le handler (DNSProber,
	// Clock, …). Le binaire scanner-dns_records y injecte un
	// DNSProber backé par dnsprobe.
	HandlerOptions scanhandler.Options
}

// Run est l'entrypoint. Renvoie un exit code (à passer à os.Exit côté
// main) — 0 = clean shutdown, 1 = erreur, 64 = mauvais usage.
func Run(cfg Config) int {
	if cfg.ScanKind == "" {
		fmt.Fprintln(os.Stderr, "runtime: ScanKind required")
		return 64
	}

	fs := flag.NewFlagSet("scanner-"+cfg.ScanKind, flag.ContinueOnError)
	var (
		idleBackoff time.Duration
		showVersion bool
		dryRun      bool
	)
	fs.DurationVar(&idleBackoff, "idle-backoff", defaultDur(cfg.IdleBackoff, time.Second), "sleep duration when the queue is empty")
	fs.BoolVar(&showVersion, "version", false, "print the worker version and exit")
	fs.BoolVar(&dryRun, "dry-run", false, "boot without DB (in-memory job/results stores)")
	if err := fs.Parse(cfg.Args); err != nil {
		return 64
	}

	queue := "scan:" + cfg.ScanKind

	if showVersion {
		fmt.Printf("scanner-%s %s\n", cfg.ScanKind, worker.Version)
		return 0
	}

	dbURL := os.Getenv("RECONAUT_DATABASE_URL")
	if dbURL == "" && !dryRun && cfg.JobStore == nil {
		fmt.Fprintln(os.Stderr, "RECONAUT_DATABASE_URL not set ; pass --dry-run to boot without a DB.")
		return 64
	}

	jobStore, resStore, closeFn, err := wireStores(cfg, dbURL, dryRun)
	if err != nil {
		log.Printf("scanner-%s: wire stores: %v", cfg.ScanKind, err)
		return 1
	}
	defer closeFn()

	handler := scanhandler.NewWithOptions(resStore, cfg.HandlerOptions)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	log.Printf("scanner-%s %s started (queue=%s, dry-run=%v)", cfg.ScanKind, worker.Version, queue, dryRun)
	processed, loopErr := goodjob.Loop(ctx, jobStore, handler, goodjob.LoopConfig{
		Queue:        queue,
		IdleBackoff:  idleBackoff,
		PanicCounter: worker.NewNoopCounter(),
	})
	log.Printf("scanner-%s shutting down (processed=%d, err=%v)", cfg.ScanKind, processed, loopErr)
	if loopErr != nil {
		return 1
	}
	return 0
}

func wireStores(cfg Config, _ string, dryRun bool) (goodjob.Store, results.Store, func(), error) {
	if cfg.JobStore != nil && cfg.ResultStore != nil {
		return cfg.JobStore, cfg.ResultStore, func() {}, nil
	}
	if dryRun || cfg.JobStore != nil {
		jobStore := cfg.JobStore
		if jobStore == nil {
			jobStore = goodjob.NewInMemoryStore()
		}
		resStore := cfg.ResultStore
		if resStore == nil {
			resStore = results.NewInMemoryStore()
		}
		return jobStore, resStore, func() {}, nil
	}
	return nil, nil, nil, fmt.Errorf("no DB driver linked ; pass --dry-run for in-memory stores")
}

func defaultDur(v, fallback time.Duration) time.Duration {
	if v > 0 {
		return v
	}
	return fallback
}
