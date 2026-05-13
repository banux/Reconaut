// SPDX-License-Identifier: AGPL-3.0-only
package mqttprobe

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"io"
	"math/big"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeMQTTBroker simule un broker MQTT scriptable. Il lit le CONNECT
// envoyé par le client, renvoie un CONNACK selon le scénario, puis
// **logue chaque byte reçu après** et fait échouer le test si > 2
// (les 2 attendus étant DISCONNECT `0xE0 0x00`).
type fakeMQTTBroker struct {
	listener net.Listener
	t        *testing.T
	wg       sync.WaitGroup

	// Scripted response
	connackReturnCode  byte
	connackSessionPres bool
	expectTLS          bool
	silentMode         bool
	httpMode           bool

	tlsCert tls.Certificate
	leafSHA string
	leafSAN string

	mu              sync.Mutex
	postConnackData []byte
}

type fakeOpts struct {
	connackReturnCode  byte
	connackSessionPres bool
	expectTLS          bool
	silent             bool
	httpMode           bool
}

func startFakeBroker(t *testing.T, opts fakeOpts) *fakeMQTTBroker {
	t.Helper()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	b := &fakeMQTTBroker{
		listener:           ln,
		t:                  t,
		connackReturnCode:  opts.connackReturnCode,
		connackSessionPres: opts.connackSessionPres,
		expectTLS:          opts.expectTLS,
		silentMode:         opts.silent,
		httpMode:           opts.httpMode,
	}
	if opts.expectTLS {
		b.tlsCert, b.leafSHA, b.leafSAN = newSelfSignedCert(t)
	}

	b.wg.Add(1)
	go b.acceptLoop()
	return b
}

func newSelfSignedCert(t *testing.T) (tls.Certificate, string, string) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("ecdsa: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(7),
		Subject:      pkix.Name{CommonName: "mqtt.test.fr"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		DNSNames:     []string{"mqtt.test.fr"},
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}
	sum := sha256.Sum256(der)
	return tls.Certificate{
		Certificate: [][]byte{der},
		PrivateKey:  priv,
	}, "sha256:" + hex.EncodeToString(sum[:]), "mqtt.test.fr"
}

func (b *fakeMQTTBroker) acceptLoop() {
	defer b.wg.Done()
	for {
		conn, err := b.listener.Accept()
		if err != nil {
			return
		}
		b.wg.Add(1)
		go b.handleConn(conn)
	}
}

func (b *fakeMQTTBroker) handleConn(rawConn net.Conn) {
	defer b.wg.Done()
	defer rawConn.Close()

	if b.silentMode {
		buf := make([]byte, 1024)
		_, _ = rawConn.Read(buf)
		return
	}
	if b.httpMode {
		_, _ = rawConn.Write([]byte("HTTP/1.1 200 OK\r\nServer: nginx\r\n\r\n"))
		return
	}

	// TLS handshake si demandé
	var conn net.Conn = rawConn
	if b.expectTLS {
		tlsConn := tls.Server(rawConn, &tls.Config{
			Certificates: []tls.Certificate{b.tlsCert},
			MinVersion:   tls.VersionTLS12,
		})
		_ = tlsConn.SetDeadline(time.Now().Add(3 * time.Second))
		if err := tlsConn.Handshake(); err != nil {
			return
		}
		conn = tlsConn
	}

	// Lecture du CONNECT (longueur variable — on lit byte par byte
	// jusqu'à avoir le remaining_length, puis le payload).
	_ = rawConn.SetReadDeadline(time.Now().Add(3 * time.Second))
	hdr := make([]byte, 1)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return
	}
	if hdr[0] != pktConnect {
		return
	}
	// Decode variable byte integer
	remaining := 0
	multiplier := 1
	for {
		b := make([]byte, 1)
		if _, err := io.ReadFull(conn, b); err != nil {
			return
		}
		remaining += int(b[0]&0x7F) * multiplier
		if b[0]&0x80 == 0 {
			break
		}
		multiplier *= 128
		if multiplier > 128*128*128 {
			return
		}
	}
	// Drain remaining bytes du CONNECT
	if remaining > 0 {
		body := make([]byte, remaining)
		if _, err := io.ReadFull(conn, body); err != nil {
			return
		}
	}

	// Envoie CONNACK
	sessionByte := byte(0x00)
	if b.connackSessionPres {
		sessionByte = 0x01
	}
	_, _ = conn.Write([]byte{pktConnack, 0x02, sessionByte, b.connackReturnCode})

	// Log tout byte reçu après le CONNACK. Le sondeur doit envoyer
	// UNIQUEMENT DISCONNECT (`0xE0 0x00`).
	_ = rawConn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	post := make([]byte, 32)
	n, _ := conn.Read(post)
	if n > 0 {
		b.mu.Lock()
		b.postConnackData = append(b.postConnackData, post[:n]...)
		b.mu.Unlock()
	}
}

func (b *fakeMQTTBroker) addr() string { return b.listener.Addr().String() }
func (b *fakeMQTTBroker) host() string { h, _, _ := net.SplitHostPort(b.addr()); return h }
func (b *fakeMQTTBroker) port() int {
	_, p, _ := net.SplitHostPort(b.addr())
	n := 0
	for _, c := range p {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}
func (b *fakeMQTTBroker) close() {
	_ = b.listener.Close()
	b.wg.Wait()
}
func (b *fakeMQTTBroker) postBytes() []byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]byte, len(b.postConnackData))
	copy(out, b.postConnackData)
	return out
}

// ----------------- TESTS -----------------

// TestProbe_SuccessAccepted : le broker accepte (rc=0).
func TestProbe_SuccessAccepted(t *testing.T) {
	srv := startFakeBroker(t, fakeOpts{connackReturnCode: 0})
	defer srv.close()

	res, err := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("expected outcome=success, got %q", res.Outcome)
	}
	if res.ReturnCode != 0 || res.ReturnCodeMeaning != "accepted" {
		t.Errorf("expected rc=0/accepted, got rc=%d/%s", res.ReturnCode, res.ReturnCodeMeaning)
	}
	if res.ProtocolLevel != 4 {
		t.Errorf("expected protocol_level=4, got %d", res.ProtocolLevel)
	}

	// Vérifier l'invariant runtime : 0 ou 2 bytes post-CONNACK.
	time.Sleep(100 * time.Millisecond)
	post := srv.postBytes()
	if len(post) > 2 {
		t.Fatalf("more than DISCONNECT observed post-CONNACK: %v", post)
	}
	// Le DISCONNECT doit être 0xE0 0x00 si présent
	if len(post) == 2 && (post[0] != 0xE0 || post[1] != 0x00) {
		t.Errorf("post-CONNACK bytes are not DISCONNECT: %v", post)
	}
}

// TestProbe_NotAuthorized : broker refuse anonymous avec rc=5.
func TestProbe_NotAuthorized(t *testing.T) {
	srv := startFakeBroker(t, fakeOpts{connackReturnCode: 5})
	defer srv.close()

	res, err := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("expected outcome=success (the probe succeeded — auth refusal is the result), got %q", res.Outcome)
	}
	if res.ReturnCode != 5 || res.ReturnCodeMeaning != "not_authorized" {
		t.Errorf("expected rc=5/not_authorized, got rc=%d/%s", res.ReturnCode, res.ReturnCodeMeaning)
	}
}

// TestProbe_UnacceptableProtocol : rc=1.
func TestProbe_UnacceptableProtocol(t *testing.T) {
	srv := startFakeBroker(t, fakeOpts{connackReturnCode: 1})
	defer srv.close()

	res, _ := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if res.ReturnCode != 1 || res.ReturnCodeMeaning != "unacceptable_protocol_version" {
		t.Errorf("expected rc=1, got rc=%d/%s", res.ReturnCode, res.ReturnCodeMeaning)
	}
}

// TestProbe_TLSCapture : sur port 8883, le sondeur fait un TLS
// handshake puis envoie le CONNECT dans le canal chiffré, et capture
// le cert.
func TestProbe_TLSCapture(t *testing.T) {
	srv := startFakeBroker(t, fakeOpts{connackReturnCode: 0, expectTLS: true})
	defer srv.close()

	res, err := Probe(context.Background(), srv.host(), Config{
		Port: srv.port(), Timeout: 2 * time.Second, TryTLSUpgrade: true,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("expected outcome=success, got %q", res.Outcome)
	}
	if res.TLSCertSHA256 != srv.leafSHA {
		t.Errorf("cert sha mismatch:\n  got      %q\n  expected %q", res.TLSCertSHA256, srv.leafSHA)
	}
	if !contains(res.TLSSANs, "mqtt.test.fr") {
		t.Errorf("expected SAN mqtt.test.fr, got %v", res.TLSSANs)
	}
	if res.TLSNotAfter == "" {
		t.Errorf("expected non-empty NotAfter")
	}
}

// TestProbe_TLSDisabled : sur port 8883 mais TryTLSUpgrade=false ET
// le broker attend du TLS — le sondeur tente du clair, ne reçoit pas
// de CONNACK valide → not_mqtt.
func TestProbe_TLSDisabled(t *testing.T) {
	srv := startFakeBroker(t, fakeOpts{connackReturnCode: 0, expectTLS: true})
	defer srv.close()

	// Force port custom (pas 8883) pour éviter l'auto-TLS, mais
	// expectTLS=true côté broker → TLS handshake jamais matché.
	cfg := Config{Port: srv.port(), Timeout: 800 * time.Millisecond, TryTLSUpgrade: false}
	// On override l'heuristique 8883→TLS en utilisant le port aléatoire.
	res, _ := Probe(context.Background(), srv.host(), cfg)
	if res.TLSCertSHA256 != "" {
		t.Errorf("expected empty TLS cert (TLS disabled), got %q", res.TLSCertSHA256)
	}
	// L'outcome peut être not_mqtt ou timeout (le broker attend TLS, ne
	// répond pas en clair).
	if res.Outcome != OutcomeNotMQTT && res.Outcome != OutcomeTimeout {
		t.Errorf("expected not_mqtt or timeout, got %q", res.Outcome)
	}
}

// TestProbe_NotMQTT : un service HTTP répond — pas un broker MQTT.
func TestProbe_NotMQTT(t *testing.T) {
	srv := startFakeBroker(t, fakeOpts{httpMode: true})
	defer srv.close()

	res, _ := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if res.Outcome != OutcomeNotMQTT {
		t.Errorf("expected outcome=not_mqtt, got %q", res.Outcome)
	}
}

// TestProbe_DialError : port fermé.
func TestProbe_DialError(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	host, p, _ := net.SplitHostPort(ln.Addr().String())
	port := 0
	for _, c := range p {
		port = port*10 + int(c-'0')
	}
	_ = ln.Close()

	res, _ := Probe(context.Background(), host, Config{Port: port, Timeout: 500 * time.Millisecond})
	if res.Outcome != OutcomeDialError {
		t.Errorf("expected outcome=dial_error, got %q", res.Outcome)
	}
}

// TestProbe_TimeoutSilentBroker : le broker ouvre TCP mais n'écrit
// jamais de CONNACK → timeout.
func TestProbe_TimeoutSilentBroker(t *testing.T) {
	srv := startFakeBroker(t, fakeOpts{silent: true})
	defer srv.close()

	start := time.Now()
	res, _ := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 300 * time.Millisecond})
	elapsed := time.Since(start)
	if elapsed > 2*time.Second {
		t.Errorf("probe took %v, expected ~300ms", elapsed)
	}
	if res.Outcome != OutcomeTimeout && res.Outcome != OutcomeNotMQTT {
		t.Errorf("expected timeout or not_mqtt, got %q", res.Outcome)
	}
}

// TestBuildConnect_Wellformed : la trame CONNECT générée est conforme.
func TestBuildConnect_Wellformed(t *testing.T) {
	pkt := buildConnect("")
	if pkt[0] != pktConnect {
		t.Errorf("type byte: got %#x, want %#x", pkt[0], pktConnect)
	}
	// remaining_length devrait être > 0 (au minimum varHeader 10 bytes + 2 bytes payload empty)
	// Le 2e byte est le 1er byte du remaining_length encoding.
	if pkt[1] == 0 {
		t.Errorf("remaining_length is 0, expected >= 12")
	}
	// Le protocol name "MQTT" est à offset 2 (length-prefix) + 2 = 4.
	if string(pkt[4:8]) != "MQTT" {
		t.Errorf("protocol name: got %q, want MQTT", string(pkt[4:8]))
	}
	// protocol level à offset 8.
	if pkt[8] != protocolLevel {
		t.Errorf("protocol level: got %#x, want %#x", pkt[8], protocolLevel)
	}
	// connect flags à offset 9.
	if pkt[9] != flagCleanSession {
		t.Errorf("connect flags: got %#x, want %#x (clean session only)", pkt[9], flagCleanSession)
	}
	// Vérifier qu'aucun bit username/password n'est set.
	if pkt[9]&0x80 != 0 || pkt[9]&0x40 != 0 {
		t.Errorf("username/password flags MUST NOT be set, got %#x", pkt[9])
	}
}

// TestConnect_NoAuthFlags : invariant critique — peu importe le
// clientID, les flags username/password/will restent à 0.
func TestConnect_NoAuthFlags(t *testing.T) {
	for _, id := range []string{"", "x", "long-client-id-xyz"} {
		pkt := buildConnect(id)
		flags := pkt[9]
		if flags&0x80 != 0 {
			t.Errorf("[clientID=%q] username flag set, got %#x", id, flags)
		}
		if flags&0x40 != 0 {
			t.Errorf("[clientID=%q] password flag set, got %#x", id, flags)
		}
		if flags&0x04 != 0 {
			t.Errorf("[clientID=%q] will flag set, got %#x", id, flags)
		}
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

// silence unused-import warnings if testing.T isn't used directly.
var _ = strings.TrimSpace
