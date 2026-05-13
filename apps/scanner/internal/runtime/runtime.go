// SPDX-License-Identifier: AGPL-3.0-only
// Package runtime assemble la boucle de claim/submit/fail HTTP via
// MCP + le handler scan. Un binaire scanner-<kind> appelle
// `runtime.Run(cfg)` et c'est tout.
//
// Source de vérité :
//
//	openspec/changes/remote-scanner-agents/specs/scanning/spec.md
//	  -> Requirement: Workers Go consomment la file via MCP HTTP
//	openspec/changes/remote-scanner-agents/specs/platform/spec.md
//	  -> Requirement: Workers déployables sans accès Postgres
//
// Les workers N'ACCÈDENT PLUS à Postgres. Variables d'env :
//   - RECONAUT_API_URL   : URL Rails (obligatoire sauf --dry-run).
//   - RECONAUT_API_KEY   : clé API avec scopes worker:claim + worker:submit.
//   - RECONAUT_WORKER_ID : identifiant logique (défaut hostname+pid).
//   - RECONAUT_API_TLS_INSECURE : "true"/"1" pour accepter cert invalide.
//
// Mode --dry-run : boucle locale sur InMemory stores, aucun appel HTTP.
package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/agentclient"
	"github.com/banux/Reconaut/apps/scanner/internal/goodjob"
	"github.com/banux/Reconaut/apps/scanner/internal/results"
	"github.com/banux/Reconaut/apps/scanner/internal/scanhandler"
	"github.com/banux/Reconaut/apps/scanner/internal/worker"
)

// Config paramètre la boucle. Chaque binaire fournit un Config.
type Config struct {
	// ScanKind pilote le QueueName consommé : "scan:<kind>".
	ScanKind string
	// IdleBackoff : sleep quand la file est vide.
	IdleBackoff time.Duration
	// Args : os.Args[1:] (utile pour les tests qui veulent forcer --dry-run).
	Args []string
	// HandlerOptions : options injectables pour le handler (Probers,
	// ScopeChecker, Clock). Le store SQL n'existe plus.
	HandlerOptions scanhandler.Options
	// Client : injectable pour les tests (fakeRails server). Si nil,
	// construit depuis les variables d'env.
	Client AgentClient
}

// AgentClient est l'interface minimale attendue par la boucle.
// agentclient.Client l'implémente ; les tests peuvent mocker.
type AgentClient interface {
	Claim(ctx context.Context, queue string, leaseSeconds int) (*agentclient.Job, error)
	Submit(ctx context.Context, jobID, idemKey, scanKind, targetKind, targetValue, status string, observedAt time.Time) error
	Fail(ctx context.Context, jobID, errMsg string) error
	Heartbeat(ctx context.Context, scanKind, version string, inflightJobs int) error
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
		idleBackoff  time.Duration
		showVersion  bool
		dryRun       bool
		leaseSeconds int
	)
	fs.DurationVar(&idleBackoff, "idle-backoff", defaultDur(cfg.IdleBackoff, time.Second), "sleep duration when the queue is empty")
	fs.BoolVar(&showVersion, "version", false, "print the worker version and exit")
	fs.BoolVar(&dryRun, "dry-run", false, "boot without backend (in-memory job/results stores, no HTTP calls)")
	fs.IntVar(&leaseSeconds, "lease-seconds", 300, "lease duration for claimed jobs (seconds, max 1800)")
	if err := fs.Parse(cfg.Args); err != nil {
		return 64
	}

	queue := "scan:" + cfg.ScanKind

	if showVersion {
		fmt.Printf("scanner-%s %s\n", cfg.ScanKind, worker.Version)
		return 0
	}

	// Mode --dry-run : pas d'agentclient, boucle locale uniquement.
	// Pratique pour smoke-tester un binaire sans Rails.
	if dryRun {
		return runDryRun(cfg, queue, idleBackoff)
	}

	client := cfg.Client
	if client == nil {
		built, err := buildClient(cfg.ScanKind)
		if err != nil {
			fmt.Fprintln(os.Stderr, err.Error())
			return 64
		}
		client = built
	}

	resStore := results.NewInMemoryStore() // pour télémétrie locale ; les résultats vrais partent vers Rails
	inflight := &atomic.Int64{}
	handler := wrapWithInflightCounter(scanhandler.NewWithOptions(resStore, cfg.HandlerOptions), inflight)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	heartbeatInterval := readHeartbeatInterval()
	go heartbeatLoop(ctx, client, cfg.ScanKind, worker.Version, inflight, heartbeatInterval)

	log.Printf("scanner-%s %s started (queue=%s, mode=agent, heartbeat_interval=%s)",
		cfg.ScanKind, worker.Version, queue, heartbeatInterval)
	processed, loopErr := agentLoop(ctx, client, handler, queue, idleBackoff, leaseSeconds)
	log.Printf("scanner-%s shutting down (processed=%d, err=%v)", cfg.ScanKind, processed, loopErr)
	if loopErr != nil {
		return 1
	}
	return 0
}

// readHeartbeatInterval lit RECONAUT_HEARTBEAT_INTERVAL (secondes,
// défaut 30, max 600). Une valeur invalide retombe sur le défaut.
func readHeartbeatInterval() time.Duration {
	const def = 30 * time.Second
	const max = 600 * time.Second
	v := os.Getenv("RECONAUT_HEARTBEAT_INTERVAL")
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		log.Printf("scanner: invalid RECONAUT_HEARTBEAT_INTERVAL=%q, falling back to %s", v, def)
		return def
	}
	d := time.Duration(n) * time.Second
	if d > max {
		return max
	}
	return d
}

// heartbeatLoop appelle client.Heartbeat à intervalle régulier jusqu'à
// l'annulation du ctx. Best-effort : un échec est loggé et le tick
// suivant est tenté.
func heartbeatLoop(ctx context.Context, client AgentClient, scanKind, version string, inflight *atomic.Int64, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// Premier heartbeat immédiat (sans attendre le 1er tick) pour
	// signaler au plus vite la présence du worker.
	if err := client.Heartbeat(ctx, scanKind, version, int(inflight.Load())); err != nil {
		log.Printf("scanner: heartbeat error (initial): %v", err)
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := client.Heartbeat(ctx, scanKind, version, int(inflight.Load())); err != nil {
				log.Printf("scanner: heartbeat error: %v", err)
			}
		}
	}
}

// wrapWithInflightCounter décore un goodjob.Handler pour incrémenter
// l'`inflight` autour de chaque appel — donne au heartbeat une mesure
// vivante du nombre de jobs en cours.
func wrapWithInflightCounter(h goodjob.Handler, inflight *atomic.Int64) goodjob.Handler {
	return func(ctx context.Context, job goodjob.Job) error {
		inflight.Add(1)
		defer inflight.Add(-1)
		return h(ctx, job)
	}
}

// runDryRun garde le comportement smoke-test : InMemory + boucle
// goodjob.Loop pour exercer le handler sans backend HTTP.
func runDryRun(cfg Config, queue string, idleBackoff time.Duration) int {
	jobStore := goodjob.NewInMemoryStore()
	resStore := results.NewInMemoryStore()
	handler := scanhandler.NewWithOptions(resStore, cfg.HandlerOptions)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	log.Printf("scanner-%s %s started (queue=%s, mode=dry-run)", cfg.ScanKind, worker.Version, queue)
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

// buildClient lit les variables d'env et construit un agentclient.
// Renvoie une erreur explicite si l'env est incomplète — fail-fast.
func buildClient(scanKind string) (AgentClient, error) {
	apiURL := os.Getenv("RECONAUT_API_URL")
	apiKey := os.Getenv("RECONAUT_API_KEY")
	if apiURL == "" {
		return nil, errors.New("RECONAUT_API_URL required (pass --dry-run to boot without a backend)")
	}
	if apiKey == "" {
		return nil, errors.New("RECONAUT_API_KEY required (pass --dry-run to boot without a backend)")
	}
	workerID := os.Getenv("RECONAUT_WORKER_ID")
	if workerID == "" {
		hostname, _ := os.Hostname()
		workerID = fmt.Sprintf("%s-%s-%d", scanKind, hostname, os.Getpid())
	}
	tlsInsecure := isTruthy(os.Getenv("RECONAUT_API_TLS_INSECURE"))
	return agentclient.New(apiURL, apiKey, workerID, tlsInsecure), nil
}

// agentLoop est la boucle de claim/process/submit. Elle ne touche
// JAMAIS la DB — toute persistance passe par le AgentClient.
func agentLoop(ctx context.Context, client AgentClient, handler goodjob.Handler, queue string, idleBackoff time.Duration, leaseSeconds int) (int, error) {
	processed := 0
	for {
		if err := ctx.Err(); err != nil {
			return processed, nil
		}

		job, err := client.Claim(ctx, queue, leaseSeconds)
		if err != nil {
			log.Printf("scanner: claim error: %v (retrying after backoff)", err)
			select {
			case <-ctx.Done():
				return processed, nil
			case <-time.After(idleBackoff):
				continue
			}
		}

		if job.Empty {
			select {
			case <-ctx.Done():
				return processed, nil
			case <-time.After(idleBackoff):
				continue
			}
		}

		// Adapte le job MCP en goodjob.Job pour réutiliser le handler.
		gjJob := goodjob.Job{
			ID:         job.ID,
			QueueName:  queue,
			Params:     job.Params,
			EnqueuedAt: time.Now().UTC(),
		}
		err = handler(ctx, gjJob)
		if err != nil {
			if ferr := client.Fail(ctx, job.ID, err.Error()); ferr != nil {
				log.Printf("scanner: fail-report error: %v", ferr)
			}
		} else {
			scanKind, _ := job.Params["scan_kind"].(string)
			targetKind, targetValue := extractTarget(job.Params)
			idemKey, _ := job.Params["idempotency_key"].(string)
			status := submissionStatus(job.Params)
			if serr := client.Submit(ctx, job.ID, idemKey, scanKind, targetKind, targetValue, status, time.Now().UTC()); serr != nil {
				log.Printf("scanner: submit error: %v", serr)
			}
		}
		processed++
	}
}

// submissionStatus construit le status à remonter à Rails. Pour la v1
// on sérialise les `findings` (sortie du handler — placeholder ok pour
// les sondeurs qui n'écrivent pas encore dans Result). Le handler
// n'expose pas sa sortie au runtime, donc on remonte "ok" — l'écriture
// scan_results contient au minimum l'idempotency_key et le target.
// Quand les handlers retourneront leur résultat via un canal dédié, on
// branchera ici.
func submissionStatus(params map[string]any) string {
	out, err := json.Marshal(map[string]any{"ok": true, "params": params})
	if err != nil {
		return "ok"
	}
	return string(out)
}

func extractTarget(params map[string]any) (string, string) {
	target, ok := params["target"].(map[string]any)
	if !ok {
		return "", ""
	}
	kind, _ := target["kind"].(string)
	value, _ := target["value"].(string)
	return kind, value
}

func defaultDur(v, fallback time.Duration) time.Duration {
	if v > 0 {
		return v
	}
	return fallback
}

func isTruthy(s string) bool {
	v := strings.ToLower(strings.TrimSpace(s))
	return v == "true" || v == "1" || v == "yes"
}
