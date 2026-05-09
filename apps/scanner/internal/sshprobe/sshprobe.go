// SPDX-License-Identifier: AGPL-3.0-only
// Package sshprobe capture la bannière SSH et le fingerprint SHA-256
// de la host-key d'une cible TCP, sans JAMAIS tenter d'authentification.
//
// Source de vérité :
//
//	openspec/changes/add-ssh-probe/specs/scanning/spec.md
//	  -> Requirement: SSH Banner and Host-Key Probe
//
// Contrat :
//
//   - Aucune authentification (pas de password, pas de clé, pas de
//     keyboard-interactive, pas de GSSAPI). Le client annonce SSH-2.0,
//     déclenche le KEX, capture la host-key dans HostKeyCallback puis
//     retourne errKeyCaptured pour interrompre le handshake AVANT toute
//     phase userauth.
//   - Format hostkey_sha256 = "sha256:<base64-no-padding>" (équivalent
//     à OpenSSH `ssh-keygen -lf` et `ssh.FingerprintSHA256`).
//   - Banner brut : la première ligne envoyée par le serveur, sans
//     parsing version/software (la couche d'analyse Rails s'en charge).
//   - Lecture pure : aucun effet de bord (pas d'écriture fichier).
//
// Le package n'importe AUCUNE construction `ssh.Password`, `ssh.PublicKeys`,
// `ssh.KeyboardInteractive`, ni `ssh.RetryableAuthMethod` — un linter CI
// (`scripts/check_ssh_probe_no_auth.sh`) garantit cet invariant.
package sshprobe

import (
	"bufio"
	"context"
	"errors"
	"net"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// Outcome enumère les issues possibles d'une sonde.
const (
	OutcomeSuccess   = "success"
	OutcomeTimeout   = "timeout"
	OutcomeReset     = "reset"
	OutcomeNotSSH    = "not_ssh"
	OutcomeDialError = "dial_error"
)

// Config paramètre la sonde.
type Config struct {
	// Port TCP cible. Défaut 22 si zéro.
	Port int
	// Timeout total de la sonde (dial + read banner + KEX). Défaut 5s.
	Timeout time.Duration
}

// Result est la sortie d'un appel à Probe.
type Result struct {
	Banner        string `json:"banner"`
	HostKeySHA256 string `json:"hostkey_sha256"`
	DurationMs    int    `json:"duration_ms"`
	BytesReceived int    `json:"bytes_received"`
	Outcome       string `json:"outcome"`
}

// errKeyCaptured est retournée par notre HostKeyCallback dès que la
// host-key est capturée, pour court-circuiter le handshake AVANT que la
// phase userauth ne soit entamée. C'est le pivot qui garantit
// "jamais d'authentification".
var errKeyCaptured = errors.New("sshprobe: host-key captured, aborting handshake")

// Probe ouvre une connexion TCP vers target sur cfg.Port (défaut 22),
// lit la bannière SSH du serveur, capture la host-key via le KEX puis
// referme. La cible est supposée déjà validée par le scope-driven
// enforcement côté Rails — Probe ne re-vérifie pas.
func Probe(ctx context.Context, target string, cfg Config) (Result, error) {
	cfg = withDefaults(cfg)
	start := time.Now()
	res := Result{Outcome: OutcomeDialError}

	addr := net.JoinHostPort(target, strconv.Itoa(cfg.Port))

	dialer := &net.Dialer{Timeout: cfg.Timeout}
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		res.Outcome = classifyDialError(err)
		res.DurationMs = msSince(start)
		return res, nil
	}
	defer conn.Close()

	deadline := time.Now().Add(cfg.Timeout)
	_ = conn.SetDeadline(deadline)

	banner, n, bannerErr := readBanner(conn)
	res.BytesReceived = n
	if bannerErr != nil {
		res.Outcome = classifyReadError(bannerErr)
		res.DurationMs = msSince(start)
		return res, nil
	}
	if !strings.HasPrefix(banner, "SSH-") {
		res.Outcome = OutcomeNotSSH
		res.DurationMs = msSince(start)
		return res, nil
	}
	res.Banner = banner

	// Host-key capture via KEX. Le HostKeyCallback est appelé AVANT la
	// phase userauth ; on capture la clé puis on retourne une erreur
	// volontaire qui annule le handshake. Aucune méthode d'auth n'est
	// déclarée (Auth: nil) — même si le HostKeyCallback échouait, le
	// client n'aurait rien à proposer côté userauth.
	var captured ssh.PublicKey
	clientCfg := &ssh.ClientConfig{
		User: "reconaut-probe",
		Auth: nil,
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			captured = key
			return errKeyCaptured
		},
		ClientVersion: "SSH-2.0-Reconaut",
		Timeout:       cfg.Timeout,
	}

	// On s'appuie sur ssh.NewClientConn pour piloter le KEX. La
	// bannière a déjà été lue côté Probe ; mais NewClientConn relance
	// son propre échange de version. Pour éviter de consommer notre
	// banner deux fois, on rouvre une connexion TCP dédiée au KEX.
	// (Ouvrir deux connexions reste raisonnable — cette sonde n'est
	// pas un chemin chaud, et c'est plus simple que de bricoler un
	// reader qui ré-injecte le banner déjà lu.)
	kexConn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		// Le port s'est fermé entre le banner et le KEX — on garde
		// le banner mais on signale l'absence de hostkey.
		res.Outcome = classifyDialError(err)
		res.DurationMs = msSince(start)
		return res, nil
	}
	defer kexConn.Close()
	_ = kexConn.SetDeadline(time.Now().Add(cfg.Timeout))

	clientConn, chans, reqs, kexErr := ssh.NewClientConn(kexConn, addr, clientCfg)
	if clientConn != nil {
		// Si malgré errKeyCaptured le handshake a réussi (ne devrait
		// pas arriver), on referme immédiatement pour ne RIEN tenter
		// au-delà du KEX.
		_ = clientConn.Close()
		// chans / reqs sont pompés à vide pour ne pas bloquer.
		go drain(chans, reqs)
	}

	if captured != nil {
		res.HostKeySHA256 = ssh.FingerprintSHA256(captured)
		res.Outcome = OutcomeSuccess
	} else {
		// KEX échoué avant que le HostKeyCallback ne soit appelé —
		// c'est typiquement un serveur qui parle un autre protocole.
		// Choix prudent : not_ssh plutôt qu'une catégorie ambiguë.
		_ = kexErr
		res.Outcome = OutcomeNotSSH
	}

	res.DurationMs = msSince(start)
	return res, nil
}

// readBanner lit la première ligne d'un flux TCP (jusqu'à \n inclus),
// la trim de \r\n et la retourne. Le compteur d'octets reçus est
// remonté pour observabilité.
func readBanner(conn net.Conn) (string, int, error) {
	br := bufio.NewReader(conn)
	line, err := br.ReadString('\n')
	if err != nil && line == "" {
		return "", 0, err
	}
	n := len(line)
	line = strings.TrimRight(line, "\r\n")
	return line, n, nil
}

// drain vide deux channels SSH non utilisés pour ne pas bloquer la
// goroutine qui les a peuplés.
func drain(chans <-chan ssh.NewChannel, reqs <-chan *ssh.Request) {
	go func() {
		for c := range chans {
			_ = c.Reject(ssh.Prohibited, "sshprobe does not open channels")
		}
	}()
	for r := range reqs {
		if r.WantReply {
			_ = r.Reply(false, nil)
		}
	}
}

func classifyDialError(err error) string {
	if err == nil {
		return OutcomeDialError
	}
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "timeout") || strings.Contains(msg, "deadline"):
		return OutcomeTimeout
	case strings.Contains(msg, "refused"):
		return OutcomeDialError
	case strings.Contains(msg, "reset"):
		return OutcomeReset
	default:
		return OutcomeDialError
	}
}

func classifyReadError(err error) string {
	if err == nil {
		return OutcomeNotSSH
	}
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		return OutcomeNotSSH
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "reset") {
		return OutcomeReset
	}
	if strings.Contains(msg, "timeout") || strings.Contains(msg, "deadline") {
		return OutcomeNotSSH
	}
	return OutcomeNotSSH
}

func withDefaults(cfg Config) Config {
	if cfg.Port == 0 {
		cfg.Port = 22
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 5 * time.Second
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

// Compile-time assertion : on importe ssh pour FingerprintSHA256 ; le
// linter check_ssh_probe_no_auth.sh garantit qu'on n'importe AUCUNE
// méthode d'auth (ssh.Password, ssh.PublicKeys, ssh.KeyboardInteractive).
