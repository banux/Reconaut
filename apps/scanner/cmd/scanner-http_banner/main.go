// SPDX-License-Identifier: AGPL-3.0-only
// scanner-http_banner : binaire spécialisé `scan:http_banner`.
//
// Cf. openspec/changes/add-http-probe/ — deuxième sondeur applicatif
// livré (après SSH). Capture la bannière HTTP/HTTPS (status, headers,
// Server, extrait HTML plafonné, ALPN, certificat TLS feuille).
//
// Variables d'environnement :
//   - RECONAUT_HTTP_PROBE_TIMEOUT     : timeout par sonde en secondes (défaut 5).
//   - RECONAUT_HTTP_PROBE_MAX_BODY_KB : taille max du body en KiB (défaut 32, max 1024).
//   - RECONAUT_HTTP_PROBE_USER_AGENT  : header User-Agent (défaut Reconaut/...).
package main

import (
	"context"
	"os"
	"strconv"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/httpprobe"
	"github.com/banux/Reconaut/apps/scanner/internal/runtime"
	"github.com/banux/Reconaut/apps/scanner/internal/scanhandler"
)

func main() {
	timeoutSec := 5
	if v := os.Getenv("RECONAUT_HTTP_PROBE_TIMEOUT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			timeoutSec = n
		}
	}
	maxBodyKB := 32
	if v := os.Getenv("RECONAUT_HTTP_PROBE_MAX_BODY_KB"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			maxBodyKB = n
		}
	}
	ua := os.Getenv("RECONAUT_HTTP_PROBE_USER_AGENT")

	prober := httpAdapter{
		cfg: httpprobe.Config{
			Timeout:      time.Duration(timeoutSec) * time.Second,
			MaxBodyBytes: maxBodyKB * 1024,
			UserAgent:    ua,
		},
	}

	os.Exit(runtime.Run(runtime.Config{
		ScanKind: "http_banner",
		Args:     os.Args[1:],
		HandlerOptions: scanhandler.Options{
			HTTPProber: prober,
		},
	}))
}

// httpAdapter adapte httpprobe.Probe à l'interface scanhandler.HTTPProber.
type httpAdapter struct {
	cfg httpprobe.Config
}

func (a httpAdapter) Probe(ctx context.Context, target string, port int, scheme string) (scanhandler.HTTPProbeResult, error) {
	cfg := a.cfg
	cfg.Port = port
	cfg.Scheme = scheme

	res, err := httpprobe.Probe(ctx, target, cfg)
	if err != nil {
		return scanhandler.HTTPProbeResult{}, err
	}
	return scanhandler.HTTPProbeResult{
		Scheme:        res.Scheme,
		Status:        res.Status,
		Headers:       res.Headers,
		Server:        res.Server,
		BodyExcerpt:   res.BodyExcerpt,
		BodyBytes:     res.BodyBytes,
		ALPN:          res.ALPN,
		TLSCertSHA256: res.TLSCertSHA256,
		TLSSANs:       res.TLSSANs,
		TLSNotAfter:   res.TLSNotAfter,
		DurationMs:    res.DurationMs,
		BytesReceived: res.BytesReceived,
		Outcome:       res.Outcome,
	}, nil
}
