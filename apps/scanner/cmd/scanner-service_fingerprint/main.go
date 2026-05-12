// SPDX-License-Identifier: AGPL-3.0-only
// scanner-service_fingerprint : binaire spécialisé `scan:service_fingerprint`.
//
// Pour la v1, ce binaire couvre le sondage SSH (banner + host-key
// SHA-256) et RDP (X.224 Negotiation + capture TLS cert opt-in),
// tous deux sans authentification.
// Cf. openspec/changes/add-ssh-probe/ et add-rdp-probe/.
//
// Les autres protocoles (MQTT, CoAP, Modbus) seront livrés par des
// changes dédiés qui ajouteront leurs adaptateurs dans scanhandler.Options
// sans modifier ce main.
//
// Variables d'environnement :
//   - RECONAUT_SSH_PROBE_TIMEOUT : timeout sonde SSH en secondes (défaut 5).
//   - RECONAUT_RDP_PROBE_TIMEOUT : timeout sonde RDP en secondes (défaut 5).
//   - RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE : "true"/"1" pour désactiver
//     l'upgrade TLS RDP (cert non capturé même si PROTOCOL_SSL annoncé).
package main

import (
	"context"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/rdpprobe"
	"github.com/banux/Reconaut/apps/scanner/internal/runtime"
	"github.com/banux/Reconaut/apps/scanner/internal/scanhandler"
	"github.com/banux/Reconaut/apps/scanner/internal/sshprobe"
)

func main() {
	sshTimeoutSec := 5
	if v := os.Getenv("RECONAUT_SSH_PROBE_TIMEOUT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			sshTimeoutSec = n
		}
	}

	rdpTimeoutSec := 5
	if v := os.Getenv("RECONAUT_RDP_PROBE_TIMEOUT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			rdpTimeoutSec = n
		}
	}

	rdpTLSUpgrade := true
	if v := strings.ToLower(strings.TrimSpace(os.Getenv("RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE"))); v == "true" || v == "1" || v == "yes" {
		rdpTLSUpgrade = false
	}

	sshProber := sshAdapter{cfg: sshprobe.Config{
		Timeout: time.Duration(sshTimeoutSec) * time.Second,
	}}

	rdpProber := rdpAdapter{cfg: rdpprobe.Config{
		Timeout:       time.Duration(rdpTimeoutSec) * time.Second,
		TryTLSUpgrade: rdpTLSUpgrade,
	}}

	os.Exit(runtime.Run(runtime.Config{
		ScanKind: "service_fingerprint",
		Args:     os.Args[1:],
		HandlerOptions: scanhandler.Options{
			SSHProber: sshProber,
			RDPProber: rdpProber,
		},
	}))
}

// sshAdapter adapte sshprobe.Probe à l'interface scanhandler.SSHProber
// (mappe sshprobe.Result → scanhandler.SSHProbeResult).
type sshAdapter struct {
	cfg sshprobe.Config
}

func (a sshAdapter) Probe(ctx context.Context, target string, port int) (scanhandler.SSHProbeResult, error) {
	cfg := a.cfg
	if port > 0 {
		cfg.Port = port
	}
	res, err := sshprobe.Probe(ctx, target, cfg)
	if err != nil {
		return scanhandler.SSHProbeResult{}, err
	}
	return scanhandler.SSHProbeResult{
		Banner:        res.Banner,
		HostKeySHA256: res.HostKeySHA256,
		DurationMs:    res.DurationMs,
		BytesReceived: res.BytesReceived,
		Outcome:       res.Outcome,
	}, nil
}

// rdpAdapter adapte rdpprobe.Probe à l'interface scanhandler.RDPProber.
type rdpAdapter struct {
	cfg rdpprobe.Config
}

func (a rdpAdapter) Probe(ctx context.Context, target string, port int) (scanhandler.RDPProbeResult, error) {
	cfg := a.cfg
	if port > 0 {
		cfg.Port = port
	}
	res, err := rdpprobe.Probe(ctx, target, cfg)
	if err != nil {
		return scanhandler.RDPProbeResult{}, err
	}
	return scanhandler.RDPProbeResult{
		ProtocolVersion:        res.ProtocolVersion,
		SecurityFlags:          res.SecurityFlags,
		NegotiationFailureCode: res.NegotiationFailureCode,
		TLSCertSHA256:          res.TLSCertSHA256,
		TLSSANs:                res.TLSSANs,
		TLSNotAfter:            res.TLSNotAfter,
		DurationMs:             res.DurationMs,
		BytesReceived:          res.BytesReceived,
		Outcome:                res.Outcome,
	}, nil
}
