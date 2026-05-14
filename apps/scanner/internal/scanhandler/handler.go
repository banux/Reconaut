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

// HTTPProber est l'interface invoquée pour les jobs
// scan_kind="http_banner". Le binaire scanner-http_banner injecte
// une implémentation backée par internal/httpprobe.
//
// Cf. openspec/changes/add-http-probe/tasks.md §2.1.
type HTTPProber interface {
	Probe(ctx context.Context, target string, port int, scheme string) (HTTPProbeResult, error)
}

// HTTPProbeResult est le format minimal qu'un HTTPProber retourne au
// handler. Mappable 1:1 avec httpprobe.Result sans coupler ce package
// à httpprobe.
type HTTPProbeResult struct {
	Scheme        string            `json:"scheme"`
	Status        int               `json:"status"`
	Headers       map[string]string `json:"headers"`
	Server        string            `json:"server"`
	BodyExcerpt   string            `json:"body_excerpt"`
	BodyBytes     int               `json:"body_bytes"`
	ALPN          []string          `json:"alpn"`
	TLSCertSHA256 string            `json:"tls_cert_sha256"`
	TLSSANs       []string          `json:"tls_sans"`
	TLSNotAfter   string            `json:"tls_not_after"`
	DurationMs    int               `json:"duration_ms"`
	BytesReceived int               `json:"bytes_received"`
	Outcome       string            `json:"outcome"`
}

// RDPProber est l'interface invoquée pour les jobs
// scan_kind="service_fingerprint" qui ciblent un host avec port=3389
// (ou options.protocols inclut "rdp"). Le binaire scanner-service_fingerprint
// injecte une implémentation backée par internal/rdpprobe.
//
// Cf. openspec/changes/add-rdp-probe/tasks.md §2.1.
type RDPProber interface {
	Probe(ctx context.Context, target string, port int) (RDPProbeResult, error)
}

// MQTTProber est l'interface invoquée pour les jobs
// scan_kind="service_fingerprint" qui ciblent un host avec port=1883
// ou 8883 (ou options.protocols inclut "mqtt"). Le binaire
// scanner-service_fingerprint injecte une implémentation backée par
// internal/mqttprobe.
//
// Cf. openspec/changes/add-mqtt-probe/tasks.md §2.1.
type MQTTProber interface {
	Probe(ctx context.Context, target string, port int) (MQTTProbeResult, error)
}

// MQTTProbeResult est le format minimal qu'un MQTTProber retourne au
// handler. Mappable 1:1 avec mqttprobe.Result sans coupler ce package
// à mqttprobe.
type MQTTProbeResult struct {
	ProtocolLevel     uint8    `json:"protocol_level"`
	ReturnCode        uint8    `json:"return_code"`
	ReturnCodeMeaning string   `json:"return_code_meaning"`
	SessionPresent    bool     `json:"session_present"`
	TLSCertSHA256     string   `json:"tls_cert_sha256"`
	TLSSANs           []string `json:"tls_sans"`
	TLSNotAfter       string   `json:"tls_not_after"`
	DurationMs        int      `json:"duration_ms"`
	BytesReceived     int      `json:"bytes_received"`
	Outcome           string   `json:"outcome"`
}

// CoAPProber est l'interface invoquée pour les jobs
// scan_kind="service_fingerprint" qui ciblent un host avec port=5683
// (ou options.protocols inclut "coap"). Le binaire
// scanner-service_fingerprint injecte une implémentation backée par
// internal/coapprobe.
//
// Cf. openspec/changes/add-coap-probe/tasks.md §2.1.
type CoAPProber interface {
	Probe(ctx context.Context, target string, port int) (CoAPProbeResult, error)
}

// CoAPProbeResult est le format minimal qu'un CoAPProber retourne au
// handler. Mappable 1:1 avec coapprobe.Result.
type CoAPProbeResult struct {
	ResponseCodeClass   uint8  `json:"response_code_class"`
	ResponseCodeDetail  uint8  `json:"response_code_detail"`
	ResponseCodeMeaning string `json:"response_code_meaning"`
	ContentFormat       int    `json:"content_format"`
	PayloadExcerpt      string `json:"payload_excerpt"`
	DurationMs          int    `json:"duration_ms"`
	BytesReceived       int    `json:"bytes_received"`
	Outcome             string `json:"outcome"`
}

// ModbusProber est l'interface invoquée pour les jobs
// scan_kind="service_fingerprint" qui ciblent un host avec port=502
// (ou options.protocols inclut "modbus"). Le binaire
// scanner-service_fingerprint injecte une implémentation backée par
// internal/modbusprobe.
//
// Cf. openspec/changes/add-worker-modbus/tasks.md §2.1.
type ModbusProber interface {
	Probe(ctx context.Context, target string, port int) (ModbusProbeResult, error)
}

// ModbusProbeResult est le format minimal qu'un ModbusProber retourne
// au handler. Mappable 1:1 avec modbusprobe.Result.
type ModbusProbeResult struct {
	VendorName         string `json:"vendor_name"`
	ProductCode        string `json:"product_code"`
	MajorMinorRevision string `json:"major_minor_revision"`
	FunctionCode       uint8  `json:"function_code"`
	ExceptionCode      uint8  `json:"exception_code"`
	ExceptionMeaning   string `json:"exception_meaning"`
	IsModbus           bool   `json:"is_modbus"`
	DurationMs         int    `json:"duration_ms"`
	BytesReceived      int    `json:"bytes_received"`
	Outcome            string `json:"outcome"`
}

// RDPProbeResult est le format minimal qu'un RDPProber retourne au
// handler. Mappable 1:1 avec rdpprobe.Result sans coupler ce package
// à rdpprobe.
type RDPProbeResult struct {
	ProtocolVersion        uint32   `json:"protocol_version"`
	SecurityFlags          []string `json:"security_flags"`
	NegotiationFailureCode uint32   `json:"negotiation_failure_code"`
	TLSCertSHA256          string   `json:"tls_cert_sha256"`
	TLSSANs                []string `json:"tls_sans"`
	TLSNotAfter            string   `json:"tls_not_after"`
	DurationMs             int      `json:"duration_ms"`
	BytesReceived          int      `json:"bytes_received"`
	Outcome                string   `json:"outcome"`
}

// ScopeChecker est la garde de défense-en-profondeur invoquée AVANT
// chaque sonde : si la cible n'est pas couverte par une entrée de
// scope active, le handler refuse de probe — aucun paquet réseau
// n'est émis. Quand nil, le handler n'applique pas de garde
// supplémentaire (Rails reste la garde primaire via ScanEnqueuer).
//
// Cf. openspec/changes/init-reconaut-platform/tasks.md §2.2.
type ScopeChecker interface {
	IsInScope(ctx context.Context, targetKind, targetValue string) (bool, error)
}

// Options permet d'injecter des collaborateurs optionnels (DNSProber
// pour le binaire dns_records, SSHProber pour service_fingerprint,
// ScopeChecker pour la garde de scope côté worker, futurs probes
// pour les autres kinds).
type Options struct {
	DNSProber    DNSProber
	SSHProber    SSHProber
	HTTPProber   HTTPProber
	RDPProber    RDPProber
	MQTTProber   MQTTProber
	CoAPProber   CoAPProber
	ModbusProber ModbusProber
	ScopeChecker ScopeChecker
	Clock        func() time.Time
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

		// Garde de scope (défense-en-profondeur) — Rails l'a déjà
		// appliquée avant enqueue, on re-vérifie côté worker pour
		// couvrir les cas (a) job inséré directement dans good_jobs,
		// (b) entrée de scope révoquée entre enqueue et claim.
		// Cf. openspec/changes/init-reconaut-platform/tasks.md §2.2.
		if opts.ScopeChecker != nil {
			inScope, err := opts.ScopeChecker.IsInScope(ctx, targetKind, targetValue)
			if err != nil {
				return fmt.Errorf("scan_handler: scope check: %w", err)
			}
			if !inScope {
				return persistOutOfScope(ctx, store, clock, idemKey, scanKind, targetKind, targetValue)
			}
		}

		// Dispatch par scan_kind.
		if scanKind == "dns_records" {
			return handleDNSRecords(ctx, store, opts.DNSProber, clock, idemKey, scanKind, targetKind, targetValue)
		}

		if scanKind == "service_fingerprint" && shouldProbeSSH(job.Params) {
			return handleSSHProbe(ctx, store, opts.SSHProber, clock, idemKey, scanKind, targetKind, targetValue, sshPort(job.Params))
		}

		if scanKind == "service_fingerprint" && shouldProbeRDP(job.Params) {
			return handleRDPProbe(ctx, store, opts.RDPProber, clock, idemKey, scanKind, targetKind, targetValue, rdpPort(job.Params))
		}

		if scanKind == "service_fingerprint" && shouldProbeMQTT(job.Params) {
			return handleMQTTProbe(ctx, store, opts.MQTTProber, clock, idemKey, scanKind, targetKind, targetValue, mqttPort(job.Params))
		}

		if scanKind == "service_fingerprint" && shouldProbeCoAP(job.Params) {
			return handleCoAPProbe(ctx, store, opts.CoAPProber, clock, idemKey, scanKind, targetKind, targetValue, coapPort(job.Params))
		}

		if scanKind == "service_fingerprint" && shouldProbeModbus(job.Params) {
			return handleModbusProbe(ctx, store, opts.ModbusProber, clock, idemKey, scanKind, targetKind, targetValue, modbusPort(job.Params))
		}

		if scanKind == "http_banner" {
			port, scheme := httpPortScheme(job.Params)
			return handleHTTPProbe(ctx, store, opts.HTTPProber, clock, idemKey, scanKind, targetKind, targetValue, port, scheme)
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

// persistOutOfScope écrit un Result avec status="out-of-scope" sans
// jamais invoquer de prober — donc sans jamais ouvrir une connexion
// réseau vers la cible. Le worker continue à fonctionner pour les
// jobs suivants. Cf. init-reconaut-platform §2.2 : "pas de paquet
// réseau émis".
func persistOutOfScope(ctx context.Context, store results.Store,
	clock func() time.Time, idemKey, scanKind, targetKind, targetValue string) error {
	result := results.Result{
		IdempotencyKey: idemKey,
		ScanKind:       scanKind,
		TargetKind:     targetKind,
		TargetValue:    targetValue,
		Status:         "out-of-scope",
		ObservedAt:     clock().UTC(),
	}
	_, err := store.Insert(ctx, result)
	if err != nil {
		return fmt.Errorf("scan_handler: persist out-of-scope: %w", err)
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

// httpPortScheme : choisit le couple (port, scheme) pour un job
// http_banner. Heuristique :
//   - findings indique TLS sur le port → scheme=https
//   - options.protocols contient "https" → scheme=https
//   - port 443 par défaut https, port < 443 défaut http
//
// Cf. add-http-probe §2.1.
func httpPortScheme(params map[string]any) (int, string) {
	port, hasPort := portFromFindings(params, "")
	if !hasPort {
		port = 80
	}

	scheme := "http"
	if hasTLSInFindings(params, port) {
		scheme = "https"
	}
	if hasProtocolInOptions(params, "https") {
		scheme = "https"
	}
	if port == 443 {
		scheme = "https"
	}
	return port, scheme
}

// hasTLSInFindings : un finding {port: P, tls: true} signale que la
// cible parle TLS sur ce port (information typiquement remontée par
// scanner-tls_capture en amont).
func hasTLSInFindings(params map[string]any, wantPort int) bool {
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
		if port != wantPort {
			continue
		}
		if tls, ok := fmap["tls"].(bool); ok && tls {
			return true
		}
		if proto, ok := fmap["protocol"].(string); ok && proto == "https" {
			return true
		}
	}
	return false
}

// shouldProbeRDP décide si un job service_fingerprint doit déclencher
// le sondeur RDP. Critères (cf. add-rdp-probe §2.1) :
//
//   - target_kind ∈ {ip, host}
//   - findings contient {port: 3389}, OU options.protocols inclut "rdp"
//
// Si le payload ne précise rien, on retourne false : le sondeur n'est
// pas invoqué tant qu'un autre acteur (scanner-tcp_probe en amont,
// ou un agent IA) n'a pas déclaré le port 3389 ouvert.
func shouldProbeRDP(params map[string]any) bool {
	targetKind, _ := extractTarget(params)
	if targetKind != "ip" && targetKind != "host" {
		return false
	}
	if hasPortInFindings(params, 3389) {
		return true
	}
	if hasProtocolInOptions(params, "rdp") {
		return true
	}
	return false
}

// rdpPort retourne le port RDP à sonder, par défaut 3389.
func rdpPort(params map[string]any) int {
	if p, ok := portFromFindings(params, "rdp"); ok {
		return p
	}
	if hasPortInFindings(params, 3389) {
		return 3389
	}
	return 3389
}

// handleRDPProbe applique la sonde RDP et persiste un Result dont le
// champ Status sérialise en JSON le RDPProbeResult.
func handleRDPProbe(ctx context.Context, store results.Store, prober RDPProber,
	clock func() time.Time, idemKey, scanKind, targetKind, targetValue string, port int) error {
	if prober == nil {
		result := results.Result{
			IdempotencyKey: idemKey,
			ScanKind:       scanKind,
			TargetKind:     targetKind,
			TargetValue:    targetValue,
			Status:         "skipped (no RDPProber wired)",
			ObservedAt:     clock().UTC(),
		}
		_, err := store.Insert(ctx, result)
		return err
	}

	probeRes, err := prober.Probe(ctx, targetValue, port)
	if err != nil {
		return fmt.Errorf("scan_handler: rdp probe: %w", err)
	}

	payload, err := json.Marshal(probeRes)
	if err != nil {
		return fmt.Errorf("scan_handler: marshal rdp probe result: %w", err)
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
		return fmt.Errorf("scan_handler: persist rdp result: %w", err)
	}
	return nil
}

// shouldProbeMQTT décide si un job service_fingerprint doit déclencher
// le sondeur MQTT. Critères (cf. add-mqtt-probe §2.1) :
//
//   - target_kind ∈ {ip, host}
//   - findings contient {port: 1883} OU {port: 8883}, OU
//     options.protocols inclut "mqtt"
func shouldProbeMQTT(params map[string]any) bool {
	targetKind, _ := extractTarget(params)
	if targetKind != "ip" && targetKind != "host" {
		return false
	}
	if hasPortInFindings(params, 1883) || hasPortInFindings(params, 8883) {
		return true
	}
	if hasProtocolInOptions(params, "mqtt") {
		return true
	}
	return false
}

// mqttPort retourne le port MQTT à sonder. Préfère 8883 (TLS) si
// annoncé dans findings, sinon 1883.
func mqttPort(params map[string]any) int {
	if hasPortInFindings(params, 8883) {
		return 8883
	}
	if hasPortInFindings(params, 1883) {
		return 1883
	}
	if p, ok := portFromFindings(params, "mqtt"); ok {
		return p
	}
	return 1883
}

// handleMQTTProbe applique la sonde MQTT et persiste un Result dont
// le champ Status sérialise le MQTTProbeResult.
func handleMQTTProbe(ctx context.Context, store results.Store, prober MQTTProber,
	clock func() time.Time, idemKey, scanKind, targetKind, targetValue string, port int) error {
	if prober == nil {
		result := results.Result{
			IdempotencyKey: idemKey,
			ScanKind:       scanKind,
			TargetKind:     targetKind,
			TargetValue:    targetValue,
			Status:         "skipped (no MQTTProber wired)",
			ObservedAt:     clock().UTC(),
		}
		_, err := store.Insert(ctx, result)
		return err
	}

	probeRes, err := prober.Probe(ctx, targetValue, port)
	if err != nil {
		return fmt.Errorf("scan_handler: mqtt probe: %w", err)
	}

	payload, err := json.Marshal(probeRes)
	if err != nil {
		return fmt.Errorf("scan_handler: marshal mqtt probe result: %w", err)
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
		return fmt.Errorf("scan_handler: persist mqtt result: %w", err)
	}
	return nil
}

// shouldProbeCoAP décide si un job service_fingerprint doit déclencher
// le sondeur CoAP. Critères (cf. add-coap-probe §2.1) :
//
//   - target_kind ∈ {ip, host}
//   - findings contient {port: 5683}, OU options.protocols inclut "coap"
func shouldProbeCoAP(params map[string]any) bool {
	targetKind, _ := extractTarget(params)
	if targetKind != "ip" && targetKind != "host" {
		return false
	}
	if hasPortInFindings(params, 5683) {
		return true
	}
	if hasProtocolInOptions(params, "coap") {
		return true
	}
	return false
}

// coapPort retourne le port CoAP à sonder, défaut 5683.
func coapPort(params map[string]any) int {
	if p, ok := portFromFindings(params, "coap"); ok {
		return p
	}
	return 5683
}

// handleCoAPProbe applique la sonde CoAP et persiste un Result dont
// le champ Status sérialise le CoAPProbeResult.
func handleCoAPProbe(ctx context.Context, store results.Store, prober CoAPProber,
	clock func() time.Time, idemKey, scanKind, targetKind, targetValue string, port int) error {
	if prober == nil {
		result := results.Result{
			IdempotencyKey: idemKey,
			ScanKind:       scanKind,
			TargetKind:     targetKind,
			TargetValue:    targetValue,
			Status:         "skipped (no CoAPProber wired)",
			ObservedAt:     clock().UTC(),
		}
		_, err := store.Insert(ctx, result)
		return err
	}

	probeRes, err := prober.Probe(ctx, targetValue, port)
	if err != nil {
		return fmt.Errorf("scan_handler: coap probe: %w", err)
	}

	payload, err := json.Marshal(probeRes)
	if err != nil {
		return fmt.Errorf("scan_handler: marshal coap probe result: %w", err)
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
		return fmt.Errorf("scan_handler: persist coap result: %w", err)
	}
	return nil
}

// shouldProbeModbus décide si un job service_fingerprint doit déclencher
// le sondeur Modbus. Critères (cf. add-worker-modbus §2.1) :
//
//   - target_kind ∈ {ip, host}
//   - findings contient {port: 502}, OU options.protocols inclut "modbus"
func shouldProbeModbus(params map[string]any) bool {
	targetKind, _ := extractTarget(params)
	if targetKind != "ip" && targetKind != "host" {
		return false
	}
	if hasPortInFindings(params, 502) {
		return true
	}
	if hasProtocolInOptions(params, "modbus") {
		return true
	}
	return false
}

// modbusPort retourne le port Modbus à sonder, défaut 502.
func modbusPort(params map[string]any) int {
	if p, ok := portFromFindings(params, "modbus"); ok {
		return p
	}
	return 502
}

// handleModbusProbe applique la sonde Modbus et persiste un Result
// dont le champ Status sérialise le ModbusProbeResult.
func handleModbusProbe(ctx context.Context, store results.Store, prober ModbusProber,
	clock func() time.Time, idemKey, scanKind, targetKind, targetValue string, port int) error {
	if prober == nil {
		result := results.Result{
			IdempotencyKey: idemKey,
			ScanKind:       scanKind,
			TargetKind:     targetKind,
			TargetValue:    targetValue,
			Status:         "skipped (no ModbusProber wired)",
			ObservedAt:     clock().UTC(),
		}
		_, err := store.Insert(ctx, result)
		return err
	}

	probeRes, err := prober.Probe(ctx, targetValue, port)
	if err != nil {
		return fmt.Errorf("scan_handler: modbus probe: %w", err)
	}

	payload, err := json.Marshal(probeRes)
	if err != nil {
		return fmt.Errorf("scan_handler: marshal modbus probe result: %w", err)
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
		return fmt.Errorf("scan_handler: persist modbus result: %w", err)
	}
	return nil
}

// handleHTTPProbe applique la sonde HTTP et persiste un Result dont le
// champ Status sérialise en JSON le HTTPProbeResult.
func handleHTTPProbe(ctx context.Context, store results.Store, prober HTTPProber,
	clock func() time.Time, idemKey, scanKind, targetKind, targetValue string,
	port int, scheme string) error {

	if prober == nil {
		// Worker démarré sans HTTPProber : on persiste un résultat
		// "no-op" plutôt que de refuser.
		result := results.Result{
			IdempotencyKey: idemKey,
			ScanKind:       scanKind,
			TargetKind:     targetKind,
			TargetValue:    targetValue,
			Status:         "skipped (no HTTPProber wired)",
			ObservedAt:     clock().UTC(),
		}
		_, err := store.Insert(ctx, result)
		return err
	}

	probeRes, err := prober.Probe(ctx, targetValue, port, scheme)
	if err != nil {
		return fmt.Errorf("scan_handler: http probe: %w", err)
	}

	payload, err := json.Marshal(probeRes)
	if err != nil {
		return fmt.Errorf("scan_handler: marshal http probe result: %w", err)
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
		return fmt.Errorf("scan_handler: persist http result: %w", err)
	}
	return nil
}
