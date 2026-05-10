// SPDX-License-Identifier: AGPL-3.0-only
// Package httpprobe capture la bannière HTTP/HTTPS d'une cible : status,
// headers, Server, extrait HTML plafonné, ALPN et certificat TLS feuille
// (HTTPS uniquement).
//
// Source de vérité :
//
//	openspec/changes/add-http-probe/specs/scanning/spec.md
//	  -> Requirement: HTTP Banner and TLS Capture
//
// Contrat strict :
//
//   - Méthodes HTTP : GET et HEAD UNIQUEMENT (le linter
//     `check_http_probe_no_offensive.sh` enforce statiquement).
//   - Pas d'authentification : aucun header Authorization, aucun cookie,
//     aucun client cert.
//   - Pas de redirect suivi : on capture la réponse 30x telle quelle.
//   - Pas de payload weaponisé : aucune chaîne de path traversal, pas
//     de XSS / Log4Shell / etc. dans le code du sondeur.
//   - InsecureSkipVerify=true au TLS : on capture le certificat même
//     invalide / expiré / self-signed. La validation est faite a posteriori
//     par la couche d'analyse Rails.
//   - Body plafonné par défaut à 32 KiB ; cap dur à 1 MiB.
package httpprobe

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Outcome enumère les issues possibles d'une sonde.
const (
	OutcomeSuccess   = "success"
	OutcomeTimeout   = "timeout"
	OutcomeReset     = "reset"
	OutcomeNotHTTP   = "not_http"
	OutcomeDialError = "dial_error"
	OutcomeTLSError  = "tls_error"
)

const (
	defaultMaxBodyBytes = 32 * 1024
	hardCapBodyBytes    = 1024 * 1024
	defaultUserAgent    = "Reconaut/dev (+https://github.com/banux/Reconaut)"
)

// Config paramètre la sonde.
type Config struct {
	// Scheme : "http" ou "https". Défaut "http".
	Scheme string
	// Port TCP cible. Défaut 80 (http) ou 443 (https).
	Port int
	// Timeout total de la sonde (dial + TLS + GET). Défaut 5 s.
	Timeout time.Duration
	// MaxBodyBytes : taille max du body lu et reflété dans BodyExcerpt.
	// Défaut 32 KiB. Cap dur 1 MiB.
	MaxBodyBytes int
	// UserAgent : header User-Agent envoyé. Défaut "Reconaut/<version> (+...)".
	UserAgent string
}

// Result est la sortie d'un appel à Probe.
type Result struct {
	Scheme        string            `json:"scheme"`
	Status        int               `json:"status"`
	Headers       map[string]string `json:"headers"`
	Server        string            `json:"server"`
	BodyExcerpt   string            `json:"body_excerpt"`
	BodyBytes     int               `json:"body_bytes"`
	ALPN          []string          `json:"alpn"`
	TLSCertSHA256 string            `json:"tls_cert_sha256"`
	TLSCertDER    []byte            `json:"tls_cert_der"`
	TLSSANs       []string          `json:"tls_sans"`
	TLSNotAfter   string            `json:"tls_not_after"`
	DurationMs    int               `json:"duration_ms"`
	BytesReceived int               `json:"bytes_received"`
	Outcome       string            `json:"outcome"`
}

// Probe ouvre une connexion HTTP(S) vers target sur cfg.Port (défaut
// 80/443 selon scheme), envoie un GET / et capture la réponse.
//
// La cible est supposée déjà validée par le scope-driven enforcement
// côté Rails ET par scopechecker côté Go ; Probe ne re-vérifie pas.
func Probe(ctx context.Context, target string, cfg Config) (Result, error) {
	cfg = withDefaults(cfg)
	start := time.Now()
	res := Result{
		Scheme:  cfg.Scheme,
		Headers: map[string]string{},
		Outcome: OutcomeDialError,
	}

	// Capture le cert via VerifyPeerCertificate. Variables locales
	// fermées par la closure pour transporter le résultat hors du Transport.
	var capturedDER []byte
	var capturedCert *x509.Certificate

	tlsCfg := &tls.Config{
		// Capture-only : on accepte n'importe quel cert pour pouvoir
		// le persister tel quel (validation a posteriori côté Rails).
		// Cf. add-http-probe proposal.
		InsecureSkipVerify: true, //nolint:gosec
		NextProtos:         []string{"h2", "http/1.1"},
		VerifyConnection: func(state tls.ConnectionState) error {
			res.ALPN = []string{state.NegotiatedProtocol}
			return nil
		},
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return nil
			}
			capturedDER = rawCerts[0]
			cert, err := x509.ParseCertificate(rawCerts[0])
			if err == nil {
				capturedCert = cert
			}
			return nil
		},
	}

	transport := &http.Transport{
		TLSClientConfig: tlsCfg,
		DialContext: (&net.Dialer{
			Timeout: cfg.Timeout,
		}).DialContext,
		// Désactive HTTP/2 forcé par défaut (laisse ALPN négocier).
		ForceAttemptHTTP2: true,
		// Pas de connexion réutilisée : chaque Probe ouvre sa propre conn.
		DisableKeepAlives: true,
	}

	client := &http.Client{
		Transport: transport,
		Timeout:   cfg.Timeout,
		// Pas de redirect suivi : on capture la 30x telle quelle.
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	url := fmt.Sprintf("%s://%s:%d/", cfg.Scheme, target, cfg.Port)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		res.DurationMs = msSince(start)
		return res, nil
	}
	req.Header.Set("User-Agent", cfg.UserAgent)
	req.Header.Set("Accept", "*/*")

	resp, err := client.Do(req)
	if err != nil {
		res.Outcome = classifyError(err)
		res.DurationMs = msSince(start)
		// Pour HTTPS où le handshake a quand même livré le cert, on
		// le garde dans le Result (utile pour debugger un cert valide
		// derrière un timeout de body).
		populateTLS(&res, capturedDER, capturedCert)
		return res, nil
	}
	defer resp.Body.Close()

	res.Status = resp.StatusCode
	for k, v := range resp.Header {
		if len(v) > 0 {
			res.Headers[k] = v[0]
		}
	}
	res.Server = resp.Header.Get("Server")

	// Lit le body jusqu'à MaxBodyBytes octets. On lit un octet de plus
	// que la cap pour détecter la troncation.
	limited := io.LimitReader(resp.Body, int64(cfg.MaxBodyBytes)+1)
	body, _ := io.ReadAll(limited)
	if len(body) > cfg.MaxBodyBytes {
		res.BodyExcerpt = string(body[:cfg.MaxBodyBytes])
		// Tente de récupérer la taille totale via Content-Length pour
		// refléter dans BytesReceived. Sinon on indique au moins
		// MaxBodyBytes+1 (preuve de troncation).
		if cl := resp.Header.Get("Content-Length"); cl != "" {
			if n, err := strconv.Atoi(cl); err == nil {
				res.BytesReceived = n
			}
		}
		if res.BytesReceived < cfg.MaxBodyBytes {
			res.BytesReceived = cfg.MaxBodyBytes + 1
		}
	} else {
		res.BodyExcerpt = string(body)
		res.BytesReceived = len(body)
	}
	res.BodyBytes = len(res.BodyExcerpt)

	populateTLS(&res, capturedDER, capturedCert)

	res.Outcome = OutcomeSuccess
	res.DurationMs = msSince(start)
	return res, nil
}

func populateTLS(res *Result, der []byte, cert *x509.Certificate) {
	if len(der) == 0 {
		return
	}
	res.TLSCertDER = der
	sum := sha256.Sum256(der)
	res.TLSCertSHA256 = hex.EncodeToString(sum[:])
	if cert == nil {
		return
	}
	res.TLSSANs = append([]string(nil), cert.DNSNames...)
	res.TLSNotAfter = cert.NotAfter.UTC().Format(time.RFC3339)
}

func classifyError(err error) string {
	if err == nil {
		return OutcomeDialError
	}
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "tls"), strings.Contains(msg, "x509"):
		return OutcomeTLSError
	case strings.Contains(msg, "timeout"), strings.Contains(msg, "deadline"):
		return OutcomeTimeout
	case strings.Contains(msg, "reset"):
		return OutcomeReset
	case strings.Contains(msg, "refused"), strings.Contains(msg, "no route"):
		return OutcomeDialError
	default:
		return OutcomeDialError
	}
}

func withDefaults(cfg Config) Config {
	if cfg.Scheme == "" {
		cfg.Scheme = "http"
	}
	if cfg.Port == 0 {
		if cfg.Scheme == "https" {
			cfg.Port = 443
		} else {
			cfg.Port = 80
		}
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 5 * time.Second
	}
	if cfg.MaxBodyBytes <= 0 {
		cfg.MaxBodyBytes = defaultMaxBodyBytes
	}
	if cfg.MaxBodyBytes > hardCapBodyBytes {
		cfg.MaxBodyBytes = hardCapBodyBytes
	}
	if cfg.UserAgent == "" {
		cfg.UserAgent = defaultUserAgent
	}
	return cfg
}

func msSince(start time.Time) int {
	d := time.Since(start)
	if d < 0 {
		return 0
	}
	return int(d / time.Millisecond)
}
