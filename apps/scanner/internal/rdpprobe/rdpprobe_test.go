// SPDX-License-Identifier: AGPL-3.0-only
package rdpprobe

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/hex"
	"io"
	"math/big"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeRDPServer rejoue un X.224 Connection Confirm scriptable et,
// optionnellement, présente un cert TLS si un upgrade arrive. Si une
// fois la réponse envoyée le client envoie le moindre byte (autre que
// les bytes TLS handshake quand upgrade activé), le test échoue —
// c'est la preuve par construction qu'aucun MCS Connect-Initial n'est
// jamais émis.
type fakeRDPServer struct {
	listener  net.Listener
	t         *testing.T
	wg        sync.WaitGroup
	tlsCert   tls.Certificate
	leafSHA   string
	leafSANs  []string
	notAfter  time.Time

	// Scripted response : si negType=Failure, on renvoie un Failure et
	// on ferme. Sinon, on renvoie un OK avec selectedProtocols=flags.
	respondNegType byte
	respondFlags   uint32
	respondFailure uint32

	// expectTLS = true → after the Negotiation Response, accept a TLS
	// handshake. Otherwise, any post-response byte fails the test.
	expectTLS bool

	// silentMode = true → accept TCP but never write anything (timeout test).
	silentMode bool
	// httpMode = true → respond with HTTP-like bytes (not_rdp test).
	httpMode bool

	mu             sync.Mutex
	postRespBytes  int  // count of bytes received after we sent our response
	tlsHandshook   bool // observed a TLS upgrade
}

type fakeRDPOpts struct {
	negType        byte
	flags          uint32
	failureCode    uint32
	expectTLS      bool
	silent         bool
	httpMode       bool
}

func startFakeRDPServer(t *testing.T, opts fakeRDPOpts) *fakeRDPServer {
	t.Helper()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	srv := &fakeRDPServer{
		listener:       ln,
		t:              t,
		respondNegType: opts.negType,
		respondFlags:   opts.flags,
		respondFailure: opts.failureCode,
		expectTLS:      opts.expectTLS,
		silentMode:     opts.silent,
		httpMode:       opts.httpMode,
	}
	if opts.expectTLS {
		srv.tlsCert, srv.leafSHA, srv.leafSANs, srv.notAfter = newSelfSignedCert(t)
	}

	srv.wg.Add(1)
	go srv.acceptLoop()
	return srv
}

func newSelfSignedCert(t *testing.T) (tls.Certificate, string, []string, time.Time) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("ecdsa: %v", err)
	}
	notAfter := time.Now().Add(24 * time.Hour).UTC().Truncate(time.Second)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(42),
		Subject:      pkix.Name{CommonName: "rdp.test.fr"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     notAfter,
		DNSNames:     []string{"rdp.test.fr"},
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}
	sum := sha256.Sum256(der)
	sha := "sha256:" + hex.EncodeToString(sum[:])
	return tls.Certificate{
		Certificate: [][]byte{der},
		PrivateKey:  priv,
	}, sha, []string{"rdp.test.fr"}, notAfter
}

func (s *fakeRDPServer) acceptLoop() {
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

func (s *fakeRDPServer) handleConn(conn net.Conn) {
	defer s.wg.Done()
	defer conn.Close()

	if s.silentMode {
		// Lecture passive — on attend que le client referme.
		buf := make([]byte, 1024)
		_, _ = conn.Read(buf)
		return
	}
	if s.httpMode {
		_, _ = conn.Write([]byte("HTTP/1.1 200 OK\r\nServer: nginx\r\n\r\n<html/>"))
		return
	}

	// Lit la Connection Request envoyée par le client.
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return
	}
	if hdr[0] != 0x03 {
		return
	}
	total := int(binary.BigEndian.Uint16(hdr[2:4]))
	body := make([]byte, total-4)
	if _, err := io.ReadFull(conn, body); err != nil {
		return
	}

	// Construit la réponse en fonction du scénario scripté.
	resp := buildScriptedConfirm(s.respondNegType, s.respondFlags, s.respondFailure)
	if _, err := conn.Write(resp); err != nil {
		return
	}

	if s.expectTLS {
		// Accepte un TLS handshake initié par le client sur la même
		// connexion. On suit le pattern d'un serveur RDP qui upgrade
		// après le X.224 Negotiation Response.
		tlsConn := tls.Server(conn, &tls.Config{
			Certificates: []tls.Certificate{s.tlsCert},
			MinVersion:   tls.VersionTLS12,
		})
		// Lit/écrit pour piloter le handshake.
		_ = tlsConn.SetDeadline(time.Now().Add(3 * time.Second))
		if err := tlsConn.Handshake(); err == nil {
			s.mu.Lock()
			s.tlsHandshook = true
			s.mu.Unlock()
			// Le client va close après le handshake. On attend le
			// close-notify ou un EOF.
			buf := make([]byte, 1024)
			for {
				_ = tlsConn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
				_, rerr := tlsConn.Read(buf)
				if rerr != nil {
					return
				}
			}
		}
		return
	}

	// Pas d'upgrade attendu : tout octet qui arrive après notre
	// réponse est un MCS Connect-Initial ou un ClientHello — au choix,
	// ça viole le contrat.
	_ = conn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	buf := make([]byte, 1024)
	for {
		nbr, rerr := conn.Read(buf)
		if nbr > 0 {
			s.mu.Lock()
			s.postRespBytes += nbr
			s.mu.Unlock()
		}
		if rerr != nil {
			return
		}
	}
}

// buildScriptedConfirm fabrique un X.224 Connection Confirm porteur
// d'un RDP Negotiation Response ou Failure selon negType.
func buildScriptedConfirm(negType byte, flags, failureCode uint32) []byte {
	// X.224 CC : <len> 0xD0 <destRef:u16> <srcRef:u16> <class:u8>
	x224 := []byte{0x00, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00}

	neg := make([]byte, 8)
	neg[0] = negType
	neg[1] = 0x00
	binary.LittleEndian.PutUint16(neg[2:4], 8)
	switch negType {
	case negTypeRespOK:
		binary.LittleEndian.PutUint32(neg[4:8], flags)
	case negTypeFailure:
		binary.LittleEndian.PutUint32(neg[4:8], failureCode)
	}

	body := append(x224, neg...)
	body[0] = byte(len(body) - 1)

	total := 4 + len(body)
	out := []byte{0x03, 0x00, 0, 0}
	binary.BigEndian.PutUint16(out[2:4], uint16(total))
	return append(out, body...)
}

func (s *fakeRDPServer) addr() string  { return s.listener.Addr().String() }
func (s *fakeRDPServer) host() string  { h, _, _ := net.SplitHostPort(s.addr()); return h }
func (s *fakeRDPServer) port() int {
	_, p, _ := net.SplitHostPort(s.addr())
	n, _ := atoi(p)
	return n
}
func (s *fakeRDPServer) close() {
	_ = s.listener.Close()
	s.wg.Wait()
}
func (s *fakeRDPServer) postBytesObserved() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.postRespBytes
}
func (s *fakeRDPServer) tlsObserved() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.tlsHandshook
}

func atoi(s string) (int, error) {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, nil
		}
		n = n*10 + int(c-'0')
	}
	return n, nil
}

// ----------------- TESTS -----------------

// TestProbe_SuccessWithTLSCapture : la cible annonce PROTOCOL_SSL,
// l'upgrade TLS réussit, le cert est capturé.
func TestProbe_SuccessWithTLSCapture(t *testing.T) {
	srv := startFakeRDPServer(t, fakeRDPOpts{
		negType:   negTypeRespOK,
		flags:     flagProtocolSSL | flagProtocolHybrid,
		expectTLS: true,
	})
	defer srv.close()

	res, err := Probe(context.Background(), srv.host(), Config{
		Port: srv.port(), Timeout: 3 * time.Second, TryTLSUpgrade: true,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("expected outcome=success, got %q", res.Outcome)
	}
	if !contains(res.SecurityFlags, "PROTOCOL_SSL") {
		t.Errorf("expected PROTOCOL_SSL in flags, got %v", res.SecurityFlags)
	}
	if res.TLSCertSHA256 != srv.leafSHA {
		t.Errorf("cert sha mismatch:\n  got      %q\n  expected %q", res.TLSCertSHA256, srv.leafSHA)
	}
	if !contains(res.TLSSANs, "rdp.test.fr") {
		t.Errorf("expected SAN rdp.test.fr, got %v", res.TLSSANs)
	}
	if res.TLSNotAfter == "" {
		t.Errorf("expected non-empty NotAfter")
	}
	// Petite attente pour que la goroutine serveur ait le temps de
	// passer le mutex post-Handshake (race avec le return client).
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) && !srv.tlsObserved() {
		time.Sleep(20 * time.Millisecond)
	}
	if !srv.tlsObserved() {
		t.Errorf("expected server to observe a TLS handshake")
	}
}

// TestProbe_SuccessNoTLSUpgrade : PROTOCOL_SSL annoncé mais TryTLSUpgrade=false
// → aucun ClientHello envoyé, succès sans cert capturé.
func TestProbe_SuccessNoTLSUpgrade(t *testing.T) {
	srv := startFakeRDPServer(t, fakeRDPOpts{
		negType:   negTypeRespOK,
		flags:     flagProtocolSSL | flagProtocolHybrid,
		expectTLS: false,
	})
	defer srv.close()

	res, err := Probe(context.Background(), srv.host(), Config{
		Port: srv.port(), Timeout: 1 * time.Second, TryTLSUpgrade: false,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("expected outcome=success, got %q", res.Outcome)
	}
	if res.TLSCertSHA256 != "" {
		t.Errorf("expected empty cert sha (TLS disabled), got %q", res.TLSCertSHA256)
	}
	// Petite latence pour laisser arriver les éventuels bytes post-response.
	time.Sleep(150 * time.Millisecond)
	if srv.postBytesObserved() > 0 {
		t.Fatalf("MCS / ClientHello observed after Negotiation Response: %d bytes (forbidden)", srv.postBytesObserved())
	}
}

// TestProbe_NegotiationFailure : la cible répond avec un Failure
// (failureCode=0x05 = SSL_NOT_ALLOWED_BY_SERVER).
func TestProbe_NegotiationFailure(t *testing.T) {
	srv := startFakeRDPServer(t, fakeRDPOpts{
		negType:     negTypeFailure,
		failureCode: 0x05,
	})
	defer srv.close()

	res, err := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second, TryTLSUpgrade: true})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeNegotiationFailure {
		t.Fatalf("expected outcome=negotiation_failure, got %q", res.Outcome)
	}
	if res.NegotiationFailureCode != 0x05 {
		t.Errorf("expected failure_code=0x05, got %#x", res.NegotiationFailureCode)
	}
}

// TestProbe_NotRDP : un service HTTP répond sur le port — on doit
// classer en not_rdp.
func TestProbe_NotRDP(t *testing.T) {
	srv := startFakeRDPServer(t, fakeRDPOpts{httpMode: true})
	defer srv.close()

	res, err := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second, TryTLSUpgrade: true})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeNotRDP {
		t.Errorf("expected outcome=not_rdp, got %q", res.Outcome)
	}
}

// TestProbe_DialError : port fermé local → dial_error.
func TestProbe_DialError(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	host, p, _ := net.SplitHostPort(ln.Addr().String())
	port, _ := atoi(p)
	_ = ln.Close()

	res, err := Probe(context.Background(), host, Config{Port: port, Timeout: 1 * time.Second})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeDialError {
		t.Errorf("expected outcome=dial_error, got %q", res.Outcome)
	}
}

// TestProbe_TimeoutOnSilentServer : serveur qui n'écrit jamais →
// timeout.
func TestProbe_TimeoutOnSilentServer(t *testing.T) {
	srv := startFakeRDPServer(t, fakeRDPOpts{silent: true})
	defer srv.close()

	start := time.Now()
	res, err := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 500 * time.Millisecond})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if time.Since(start) > 3*time.Second {
		t.Errorf("probe took too long: %v", time.Since(start))
	}
	if res.Outcome != OutcomeTimeout && res.Outcome != OutcomeNotRDP {
		t.Errorf("expected outcome=timeout or not_rdp, got %q", res.Outcome)
	}
}

// TestProbe_NoMCSAfterResponse : invariant clé du contrat.
// On laisse expectTLS=false et TryTLSUpgrade=true — la cible annonce
// PROTOCOL_SSL pour tenter le sondeur, mais le serveur ne sert PAS
// le TLS et observe les bytes reçus. Le sondeur enverra un ClientHello
// (TLS upgrade demandé) — c'est attendu et observé via le compteur ;
// ce qu'on veut prouver, c'est qu'AUCUN MCS Connect-Initial n'est
// envoyé après ça. En pratique on regarde une variante où
// TryTLSUpgrade=false : alors postBytesObserved DOIT être 0.
func TestProbe_NoMCSAfterResponse(t *testing.T) {
	srv := startFakeRDPServer(t, fakeRDPOpts{
		negType:   negTypeRespOK,
		flags:     flagProtocolRDP, // pas de SSL → pas d'upgrade côté sondeur
		expectTLS: false,
	})
	defer srv.close()

	_, err := Probe(context.Background(), srv.host(), Config{
		Port: srv.port(), Timeout: 1 * time.Second, TryTLSUpgrade: true,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	time.Sleep(200 * time.Millisecond)
	if srv.postBytesObserved() != 0 {
		t.Fatalf("post-response bytes observed: %d (no MCS allowed)", srv.postBytesObserved())
	}
}

// TestBuildConnectionRequest_Roundtrip : la trame construite est lisible
// par readTPKT puis parseConnectionRequest miroir (smoke).
func TestBuildConnectionRequest_Wellformed(t *testing.T) {
	pkt := buildConnectionRequest("mstshash=", requestedProtocolMask)
	if pkt[0] != 0x03 {
		t.Errorf("TPKT version: got %#x", pkt[0])
	}
	total := int(binary.BigEndian.Uint16(pkt[2:4]))
	if total != len(pkt) {
		t.Errorf("TPKT length mismatch: got %d, len=%d", total, len(pkt))
	}
	if !strings.Contains(string(pkt), "Cookie: mstshash=\r\n") {
		t.Errorf("Cookie chunk not present in packet: %q", string(pkt))
	}
	// Last 8 bytes = RDP Negotiation Request.
	neg := pkt[len(pkt)-8:]
	if neg[0] != negTypeRequest {
		t.Errorf("neg type: got %#x, want %#x", neg[0], negTypeRequest)
	}
	if binary.LittleEndian.Uint32(neg[4:8]) != requestedProtocolMask {
		t.Errorf("requested protocols mask: got %#x", binary.LittleEndian.Uint32(neg[4:8]))
	}
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
