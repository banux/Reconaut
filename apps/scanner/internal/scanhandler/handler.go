// SPDX-License-Identifier: AGPL-3.0-only
// Package scanhandler builds the goodjob.Handler executed per scan
// job by the scanner-<kind> binaries.
//
// Spec sources :
//   - openspec/changes/add-tech-stack/tasks.md §5.1 (squelette no-op)
//   - openspec/changes/add-dns-records-scanner/tasks.md §2.3
//     (dispatch dns_records vers le sondeur dnsprobe)
//
// New builds a goodjob.Handler that:
//
//  1. Validates the claimed job's params against ScanJobV1.
//  2. Dispatches per scan_kind :
//     - "dns_records" → invokes the DNSProber (cf. internal/dnsprobe)
//       and persists one Result per resolved record (la valeur du
//       record est sérialisée en JSON dans Status).
//     - autre kind → placeholder no-op (la vraie sonde sera livrée
//       par les changes `scan-engine-<protocol>`).
//  3. Persists a Result keyed by the payload's idempotency_key. Le
//     store applique "insert if new" — réinjection du même
//     idempotency_key est acquittée sans seconde écriture.
//
// Standalone package (not under internal/worker) to keep the import
// graph acyclic : goodjob imports worker for SafeRun, scanhandler
// imports both goodjob and results.

package scanhandler

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/goodjob"
	"github.com/banux/Reconaut/apps/scanner/internal/jobschema"
	"github.com/banux/Reconaut/apps/scanner/internal/results"
)

// DNSProber est l'interface invoquée pour les jobs scan_kind="dns_records".
// Le binaire scanner-dns_records injecte une implémentation backée par
// internal/dnsprobe ; les autres binaires laissent ce champ nil et le
// handler retombe sur le placeholder no-op si jamais un job
// dns_records leur arrive (ne doit pas se produire car les queues
// sont spécialisées, mais c'est une sécurité).
type DNSProber interface {
	Resolve(ctx context.Context, target string) ([]ResolvedRecord, error)
}

// ResolvedRecord est le format minimal qu'un DNSProber retourne au
// handler. Mappable 1:1 avec dnsprobe.Record sans coupler ce package
// à dnsprobe.
type ResolvedRecord struct {
	RecordType string
	Name       string
	Value      string
	TTL        uint32
}

// SSHProber est l'interface invoquée pour les jobs
// scan_kind="service_fingerprint" qui ciblent un host avec port=22 (ou
// options.protocols inclut "ssh"). Le binaire scanner-service_fingerprint
// injecte une implémentation backée par internal/sshprobe.
//
// Cf. openspec/changes/add-ssh-probe/tasks.md §2.1.
type SSHProber interface {
	Probe(ctx context.Context, target string, port int) (SSHProbeResult, error)
}

// SSHProbeResult est le format minimal qu'un SSHProber retourne au
// handler. Mappable 1:1 avec sshprobe.Result sans coupler ce package
// à sshprobe.
type SSHProbeResult struct {
	Banner        string `json:"banner"`
	HostKeySHA256 string `json:"hostkey_sha256"`
	DurationMs    int    `json:"duration_ms"`
	BytesReceived int    `json:"bytes_received"`
	Outcome       string `json:"outcome"`
}

// Options permet d'injecter des collaborateurs optionnels (DNSProber
// pour le binaire dns_records, SSHProber pour service_fingerprint,
// futurs probes pour les autres kinds).
type Options struct {
	DNSProber DNSProber
	SSHProber SSHProber
	Clock     func() time.Time
}

// New retourne un goodjob.Handler en s'appuyant sur le store pour la
// persistance et, optionnellement, sur les probes injectées.
func New(store results.Store, clock func() time.Time) goodjob.Handler {
	return NewWithOptions(store, Options{Clock: clock})
}

// NewWithOptions est la variante extensible de New. Le binaire
// scanner-dns_records appelle ce constructeur avec un DNSProber.
func NewWithOptions(store results.Store, opts Options) goodjob.Handler {
	clock := opts.Clock
	if clock == nil {
		clock = time.Now
	}
	return func(ctx context.Context, job goodjob.Job) error {
		raw, err := json.Marshal(job.Params)
		if err != nil {
			return fmt.Errorf("scan_handler: marshal params: %w", err)
		}
		errs, err := jobschema.Validate(jobschema.NameScanJobV1, raw)
		if err != nil {
			return fmt.Errorf("scan_handler: validate %s: %w", jobschema.NameScanJobV1, err)
		}
		if len(errs) > 0 {
			return fmt.Errorf("scan_handler: invalid ScanJobV1: %v", errs)
		}

		idemKey, _ := job.Params["idempotency_key"].(string)
		scanKind, _ := job.Params["scan_kind"].(string)
		targetKind, targetValue := extractTarget(job.Params)

		// Dispatch par scan_kind.
		if scanKind == "dns_records" {
			return handleDNSRecords(ctx, store, opts.DNSProber, clock, idemKey, scanKind, targetKind, targetValue)
		}

		if scanKind == "service_fingerprint" && shouldProbeSSH(job.Params) {
			return handleSSHProbe(ctx, store, opts.SSHProber, clock, idemKey, scanKind, targetKind, targetValue, sshPort(job.Params))
		}

		// Placeholder no-op : la vraie sonde sera livrée par les
		// changes `scan-engine-<protocol>`. On enregistre simplement
		// un résultat "ok" pour matérialiser le passage du worker.
		result := results.Result{
			IdempotencyKey: idemKey,
			ScanKind:       scanKind,
			TargetKind:     targetKind,
			TargetValue:    targetValue,
			Status:         "ok",
			ObservedAt:     clock().UTC(),
		}
		_, err = store.Insert(ctx, result)
		if err != nil {
			return fmt.Errorf("scan_handler: persist result: %w", err)
		}
		return nil
	}
}

// handleDNSRecords applique la logique spécifique dns_records :
//   - vérifie que target_kind ∈ {domain, host} (deuxième barrière —
//     Rails refuse déjà avant enqueue, mais on défend en profondeur).
//   - invoque le DNSProber injecté.
//   - insère le résultat agrégé en sérialisant les records en JSON
//     dans le champ Status (en attendant que init-reconaut-platform
//     §2.1 livre une colonne `findings jsonb` dédiée).
func handleDNSRecords(ctx context.Context, store results.Store, prober DNSProber,
	clock func() time.Time, idemKey, scanKind, targetKind, targetValue string) error {
	if targetKind != "domain" && targetKind != "host" {
		return fmt.Errorf("scan_handler: dns_records requires target_kind in {domain, host}, got %q", targetKind)
	}
	if prober == nil {
		// Worker démarré sans DNSProber : on persiste un résultat
		// "no-op" plutôt que de refuser, pour ne pas bloquer la file
		// pendant le câblage.
		result := results.Result{
			IdempotencyKey: idemKey,
			ScanKind:       scanKind,
			TargetKind:     targetKind,
			TargetValue:    targetValue,
			Status:         "skipped (no DNSProber wired)",
			ObservedAt:     clock().UTC(),
		}
		_, err := store.Insert(ctx, result)
		return err
	}

	records, err := prober.Resolve(ctx, targetValue)
	if err != nil {
		return fmt.Errorf("scan_handler: dns resolve: %w", err)
	}

	// Sérialise les records en JSON dans le champ Status (transitoire
	// — la table `findings jsonb` côté init-reconaut-platform §2.1
	// remplacera ce stockage tassé).
	payload, err := json.Marshal(map[string]any{
		"records": records,
		"count":   len(records),
	})
	if err != nil {
		return fmt.Errorf("scan_handler: marshal findings: %w", err)
	}
	result := results.Result{
		IdempotencyKey: idemKey,
		ScanKind:       scanKind,
		TargetKind:     targetKind,
		TargetValue:    targetValue,
		Status:         string(payload),
		ObservedAt:     clock().UTC(),
	}
	_, err = store.Insert(ctx, result)
	if err != nil {
		return fmt.Errorf("scan_handler: persist dns result: %w", err)
	}
	return nil
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

// shouldProbeSSH décide si un job service_fingerprint doit déclencher
// le sondeur SSH. Critères (cf. add-ssh-probe §2.1) :
//
//   - target_kind ∈ {ip, host}
//   - findings contient {port: 22}, OU options.protocols inclut "ssh"
//
// Si le payload ne précise rien, on retourne false : le sondeur n'est
// pas invoqué tant qu'un autre acteur (le scanner tcp_probe en amont,
// ou un agent IA) n'a pas déclaré le port 22 ouvert.
func shouldProbeSSH(params map[string]any) bool {
	targetKind, _ := extractTarget(params)
	if targetKind != "ip" && targetKind != "host" {
		return false
	}
	if hasPortInFindings(params, 22) {
		return true
	}
	if hasProtocolInOptions(params, "ssh") {
		return true
	}
	return false
}

// sshPort retourne le port SSH à sonder, par défaut 22. Permet de
// supporter dans le futur des serveurs SSH sur ports non-standard
// (cf. proposal "Configuration de port non-standard" dans le différé).
func sshPort(params map[string]any) int {
	if p, ok := portFromFindings(params, "ssh"); ok {
		return p
	}
	if p, ok := portFromFindings(params, ""); ok {
		return p
	}
	return 22
}

// hasPortInFindings inspecte params["findings"] (slice de
// map[string]any) à la recherche d'un objet portant {port: <port>}.
func hasPortInFindings(params map[string]any, want int) bool {
	findings, ok := params["findings"].([]any)
	if !ok {
		return false
	}
	for _, f := range findings {
		fmap, ok := f.(map[string]any)
		if !ok {
			continue
		}
		port, _ := numberAsInt(fmap["port"])
		if port == want {
			return true
		}
	}
	return false
}

// hasProtocolInOptions inspecte params["options"]["protocols"] (slice
// de string) à la recherche d'un protocole donné.
func hasProtocolInOptions(params map[string]any, want string) bool {
	options, ok := params["options"].(map[string]any)
	if !ok {
		return false
	}
	protos, ok := options["protocols"].([]any)
	if !ok {
		return false
	}
	for _, p := range protos {
		s, _ := p.(string)
		if s == want {
			return true
		}
	}
	return false
}

// portFromFindings retourne le premier port trouvé dans findings,
// optionnellement filtré par protocole.
func portFromFindings(params map[string]any, proto string) (int, bool) {
	findings, ok := params["findings"].([]any)
	if !ok {
		return 0, false
	}
	for _, f := range findings {
		fmap, ok := f.(map[string]any)
		if !ok {
			continue
		}
		if proto != "" {
			p, _ := fmap["protocol"].(string)
			if p != proto {
				continue
			}
		}
		port, ok := numberAsInt(fmap["port"])
		if ok {
			return port, true
		}
	}
	return 0, false
}

func numberAsInt(v any) (int, bool) {
	switch n := v.(type) {
	case int:
		return n, true
	case int64:
		return int(n), true
	case float64:
		return int(n), true
	}
	return 0, false
}

// handleSSHProbe applique la sonde SSH et persiste un Result dont le
// champ Status sérialise en JSON le SSHProbeResult.
func handleSSHProbe(ctx context.Context, store results.Store, prober SSHProber,
	clock func() time.Time, idemKey, scanKind, targetKind, targetValue string, port int) error {
	if prober == nil {
		// Worker démarré sans SSHProber : on persiste un résultat
		// "no-op" plutôt que de refuser, pour ne pas bloquer la file
		// pendant le câblage.
		result := results.Result{
			IdempotencyKey: idemKey,
			ScanKind:       scanKind,
			TargetKind:     targetKind,
			TargetValue:    targetValue,
			Status:         "skipped (no SSHProber wired)",
			ObservedAt:     clock().UTC(),
		}
		_, err := store.Insert(ctx, result)
		return err
	}

	probeRes, err := prober.Probe(ctx, targetValue, port)
	if err != nil {
		return fmt.Errorf("scan_handler: ssh probe: %w", err)
	}

	payload, err := json.Marshal(probeRes)
	if err != nil {
		return fmt.Errorf("scan_handler: marshal ssh probe result: %w", err)
	}
	result := results.Result{
		IdempotencyKey: idemKey,
		ScanKind:       scanKind,
		TargetKind:     targetKind,
		TargetValue:    targetValue,
		Status:         string(payload),
		ObservedAt:     clock().UTC(),
	}
	_, err = store.Insert(ctx, result)
	if err != nil {
		return fmt.Errorf("scan_handler: persist ssh result: %w", err)
	}
	return nil
}
