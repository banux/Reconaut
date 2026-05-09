// SPDX-License-Identifier: AGPL-3.0-only
package sshprobe

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// fakeSSHServer démarre un serveur SSH local éphémère avec des
// callbacks d'auth qui font échouer le test si jamais ils sont
// invoqués — c'est la preuve par construction que le sondeur
// n'envoie aucun message userauth.
type fakeSSHServer struct {
	listener      net.Listener
	hostKey       ssh.Signer
	wg            sync.WaitGroup
	t             *testing.T
	mu            sync.Mutex
	authAttempted bool
}

func startFakeSSHServer(t *testing.T) *fakeSSHServer {
	t.Helper()

	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("ecdsa generate: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatalf("ssh signer: %v", err)
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	srv := &fakeSSHServer{listener: ln, hostKey: signer, t: t}

	srv.wg.Add(1)
	go srv.acceptLoop()
	return srv
}

func (s *fakeSSHServer) acceptLoop() {
	defer s.wg.Done()
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			return
		}
		s.wg.Add(1)
		go s.handleConn(conn)
	}
}

func (s *fakeSSHServer) handleConn(conn net.Conn) {
	defer s.wg.Done()
	defer conn.Close()

	cfg := &ssh.ServerConfig{
		PasswordCallback: func(ssh.ConnMetadata, []byte) (*ssh.Permissions, error) {
			s.mu.Lock()
			s.authAttempted = true
			s.mu.Unlock()
			s.t.Errorf("PasswordCallback invoked — sshprobe MUST NOT attempt auth")
			return nil, ssh.ErrNoAuth
		},
		PublicKeyCallback: func(ssh.ConnMetadata, ssh.PublicKey) (*ssh.Permissions, error) {
			s.mu.Lock()
			s.authAttempted = true
			s.mu.Unlock()
			s.t.Errorf("PublicKeyCallback invoked — sshprobe MUST NOT attempt auth")
			return nil, ssh.ErrNoAuth
		},
		KeyboardInteractiveCallback: func(ssh.ConnMetadata, ssh.KeyboardInteractiveChallenge) (*ssh.Permissions, error) {
			s.mu.Lock()
			s.authAttempted = true
			s.mu.Unlock()
			s.t.Errorf("KeyboardInteractiveCallback invoked — sshprobe MUST NOT attempt auth")
			return nil, ssh.ErrNoAuth
		},
	}
	cfg.AddHostKey(s.hostKey)

	// Le client va couper le handshake après le KEX (HostKeyCallback
	// retourne errKeyCaptured). NewServerConn renvoie alors une erreur,
	// qu'on ignore — c'est le comportement attendu.
	_, _, _, _ = ssh.NewServerConn(conn, cfg)
}

func (s *fakeSSHServer) addr() string {
	return s.listener.Addr().String()
}

func (s *fakeSSHServer) host() string {
	host, _, _ := net.SplitHostPort(s.addr())
	return host
}

func (s *fakeSSHServer) port() int {
	_, p, _ := net.SplitHostPort(s.addr())
	var port int
	for _, c := range p {
		port = port*10 + int(c-'0')
	}
	return port
}

func (s *fakeSSHServer) close() {
	_ = s.listener.Close()
	s.wg.Wait()
}

func (s *fakeSSHServer) authWasAttempted() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.authAttempted
}

func TestProbe_Success(t *testing.T) {
	srv := startFakeSSHServer(t)
	defer srv.close()

	res, err := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 3 * time.Second})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("expected outcome=success, got %q", res.Outcome)
	}
	if !strings.HasPrefix(res.Banner, "SSH-2.0-") {
		t.Errorf("expected banner SSH-2.0-..., got %q", res.Banner)
	}
	if !strings.HasPrefix(res.HostKeySHA256, "SHA256:") {
		t.Errorf("expected hostkey sha256 prefix, got %q", res.HostKeySHA256)
	}
	if srv.authWasAttempted() {
		t.Fatal("sshprobe attempted auth — invariant violated")
	}
	if res.DurationMs <= 0 {
		t.Errorf("expected duration_ms > 0, got %d", res.DurationMs)
	}
}

// TestProbe_FingerprintMatchesLib compare la sortie du sondeur à
// ssh.FingerprintSHA256 calculée directement sur la host-key — c'est
// l'invariant "format aligné OpenSSH `ssh-keygen -lf`".
func TestProbe_FingerprintMatchesLib(t *testing.T) {
	srv := startFakeSSHServer(t)
	defer srv.close()

	expected := ssh.FingerprintSHA256(srv.hostKey.PublicKey())

	res, err := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 3 * time.Second})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.HostKeySHA256 != expected {
		t.Fatalf("hostkey mismatch:\n  got      %q\n  expected %q", res.HostKeySHA256, expected)
	}
}

// TestProbe_NotSSH fait pointer le sondeur sur un service HTTP : le
// banner doit ne pas commencer par SSH-, donc outcome=not_ssh.
func TestProbe_NotSSH(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		_, _ = c.Write([]byte("HTTP/1.1 200 OK\r\nServer: nginx\r\n\r\n"))
	}()

	host, p, _ := net.SplitHostPort(ln.Addr().String())
	var port int
	for _, c := range p {
		port = port*10 + int(c-'0')
	}

	res, err := Probe(context.Background(), host, Config{Port: port, Timeout: 1 * time.Second})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeNotSSH {
		t.Errorf("expected outcome=not_ssh, got %q", res.Outcome)
	}
	if res.HostKeySHA256 != "" {
		t.Errorf("expected empty hostkey, got %q", res.HostKeySHA256)
	}
}

// TestProbe_DialError pointe sur un port fermé → outcome=dial_error.
func TestProbe_DialError(t *testing.T) {
	// Trouve un port libre puis le ferme — la sonde tombera sur un
	// "connection refused".
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	host, p, _ := net.SplitHostPort(ln.Addr().String())
	var port int
	for _, c := range p {
		port = port*10 + int(c-'0')
	}
	_ = ln.Close()

	res, err := Probe(context.Background(), host, Config{Port: port, Timeout: 1 * time.Second})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeDialError {
		t.Errorf("expected outcome=dial_error, got %q (banner=%q)", res.Outcome, res.Banner)
	}
}

// TestProbe_TimeoutOnSilentServer démarre un serveur TCP qui n'envoie
// JAMAIS de banner. La sonde doit retourner not_ssh (le port est ouvert
// mais le serveur ne parle pas SSH dans le timeout) ou timeout selon
// la classification.
func TestProbe_TimeoutOnSilentServer(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		// Garde la connexion ouverte sans rien écrire jusqu'à ce que
		// le client referme.
		buf := make([]byte, 1)
		_, _ = c.Read(buf)
		_ = c.Close()
	}()

	host, p, _ := net.SplitHostPort(ln.Addr().String())
	var port int
	for _, c := range p {
		port = port*10 + int(c-'0')
	}

	start := time.Now()
	res, err := Probe(context.Background(), host, Config{Port: port, Timeout: 500 * time.Millisecond})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	elapsed := time.Since(start)
	if elapsed > 3*time.Second {
		t.Errorf("probe took too long: %v (timeout was 500ms)", elapsed)
	}
	if res.Outcome != OutcomeNotSSH && res.Outcome != OutcomeTimeout {
		t.Errorf("expected outcome=not_ssh or timeout, got %q", res.Outcome)
	}
}

// TestProbe_NoAuthAttempted vérifie l'invariant central : aucun
// callback d'auth n'est invoqué côté serveur.
func TestProbe_NoAuthAttempted(t *testing.T) {
	srv := startFakeSSHServer(t)
	defer srv.close()

	_, err := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 3 * time.Second})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	// Petite latence pour laisser le serveur logger un éventuel
	// callback d'auth (théoriquement impossible — mais test défensif).
	time.Sleep(50 * time.Millisecond)
	if srv.authWasAttempted() {
		t.Fatal("sshprobe MUST NOT attempt auth — fake server saw a userauth callback")
	}
}
