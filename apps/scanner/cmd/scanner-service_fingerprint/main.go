// SPDX-License-Identifier: AGPL-3.0-only
// scanner-service_fingerprint : binaire spécialisé `scan:service_fingerprint`.
//
// Pour la v1, ce binaire couvre le sondage SSH (banner + host-key
// SHA-256, sans authentification) — premier sondeur applicatif livré.
// Cf. openspec/changes/add-ssh-probe/.
//
// Les autres protocoles (HTTP, RDP, MQTT, CoAP, Modbus) seront livrés
// par des changes dédiés (`add-http-probe`, etc.) qui ajouteront leurs
// adaptateurs dans scanhandler.Options sans modifier ce main.
//
// Variables d'environnement :
//   - RECONAUT_SSH_PROBE_TIMEOUT : timeout par sonde en secondes (défaut 5).
package main

import (
	"context"
	"os"
	"strconv"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/runtime"
	"github.com/banux/Reconaut/apps/scanner/internal/scanhandler"
	"github.com/banux/Reconaut/apps/scanner/internal/sshprobe"
)

func main() {
	timeoutSec := 5
	if v := os.Getenv("RECONAUT_SSH_PROBE_TIMEOUT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			timeoutSec = n
		}
	}

	prober := sshAdapter{cfg: sshprobe.Config{
		Timeout: time.Duration(timeoutSec) * time.Second,
	}}

	os.Exit(runtime.Run(runtime.Config{
		ScanKind: "service_fingerprint",
		Args:     os.Args[1:],
		HandlerOptions: scanhandler.Options{
			SSHProber: prober,
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
