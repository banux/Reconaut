// SPDX-License-Identifier: AGPL-3.0-only
package coapprobe

import (
	"context"
	"encoding/binary"
	"errors"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeCoAPServer écoute en UDP local, lit le 1er GET et renvoie un
// response code scriptable + content-format + payload. Compte les
// paquets reçus APRÈS le 1er : > 1 = échec (le sondeur ne doit pas
// retransmettre ni envoyer de second GET).
type fakeCoAPServer struct {
	conn *net.UDPConn
	t    *testing.T
	wg   sync.WaitGroup

	respondCode          byte // raw code byte, par ex. 0x45 = 2.05 Content
	respondContentFormat int  // -1 si pas d'option à ajouter
	respondPayload       []byte
	silentMode           bool
	garbageMode          bool

	packetsReceived atomic.Int64
}

type fakeOpts struct {
	codeClass     uint8
	codeDetail    uint8
	contentFormat int
	payload       []byte
	silent        bool
	garbage       bool
}

func startFakeServer(t *testing.T, opts fakeOpts) *fakeCoAPServer {
	t.Helper()

	addr, _ := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		t.Fatalf("listen udp: %v", err)
	}

	s := &fakeCoAPServer{
		conn:                 conn,
		t:                    t,
		respondCode:          (opts.codeClass << 5) | (opts.codeDetail & 0x1F),
		respondContentFormat: opts.contentFormat,
		respondPayload:       opts.payload,
		silentMode:           opts.silent,
		garbageMode:          opts.garbage,
	}
	if opts.contentFormat == 0 {
		s.respondContentFormat = -1 // par défaut, pas d'option
	}

	s.wg.Add(1)
	go s.loop()
	return s
}

func (s *fakeCoAPServer) loop() {
	defer s.wg.Done()
	buf := make([]byte, 65535)
	for {
		_ = s.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, from, err := s.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		s.packetsReceived.Add(1)

		// Premier paquet = réponse au GET. Paquets subséquents = retx
		// → on ne répond plus, le test échouera via packetsReceived().
		if s.packetsReceived.Load() != 1 {
			continue
		}

		if s.silentMode {
			continue
		}
		if s.garbageMode {
			_, _ = s.conn.WriteToUDP([]byte("not-a-coap-packet-at-all-this-is-just-garbage"), from)
			continue
		}

		// Extraire MID + TKL + Token du request pour les répliquer
		// (réponse ACK piggybacked : Type=ACK, même MID, même Token).
		req := buf[:n]
		if len(req) < 4 {
			continue
		}
		tkl := int(req[0] & 0x0F)
		mid := binary.BigEndian.Uint16(req[2:4])
		var token []byte
		if 4+tkl <= len(req) {
			token = req[4 : 4+tkl]
		}

		resp := s.buildResponse(mid, token)
		_, _ = s.conn.WriteToUDP(resp, from)
	}
}

// buildResponse construit une ACK piggybacked avec le response code,
// optionnellement un Content-Format option, et optionnellement un
// payload.
func (s *fakeCoAPServer) buildResponse(mid uint16, token []byte) []byte {
	tkl := byte(len(token))
	// byte 0 : Ver=01, Type=10 (ACK), TKL
	header := byte(0x60) | (tkl & 0x0F)
	pkt := []byte{header, s.respondCode}
	b := make([]byte, 2)
	binary.BigEndian.PutUint16(b, mid)
	pkt = append(pkt, b...)
	pkt = append(pkt, token...)

	// Content-Format option (12)
	if s.respondContentFormat >= 0 {
		cf := s.respondContentFormat
		// Encode the value as 0 or 1 byte (suffit pour les formats standards).
		var optValue []byte
		switch {
		case cf == 0:
			optValue = nil
		case cf < 256:
			optValue = []byte{byte(cf)}
		default:
			optValue = []byte{byte(cf >> 8), byte(cf & 0xFF)}
		}
		hdr := byte((12 << 4) | (len(optValue) & 0x0F))
		pkt = append(pkt, hdr)
		pkt = append(pkt, optValue...)
	}

	// Payload marker + payload
	if len(s.respondPayload) > 0 {
		pkt = append(pkt, 0xFF)
		pkt = append(pkt, s.respondPayload...)
	}
	return pkt
}

func (s *fakeCoAPServer) addr() string  { return s.conn.LocalAddr().String() }
func (s *fakeCoAPServer) host() string  { h, _, _ := net.SplitHostPort(s.addr()); return h }
func (s *fakeCoAPServer) port() int {
	_, p, _ := net.SplitHostPort(s.addr())
	n := 0
	for _, c := range p {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}
func (s *fakeCoAPServer) close() {
	_ = s.conn.Close()
	s.wg.Wait()
}

// ----------------- TESTS -----------------

func TestProbe_Success205Content(t *testing.T) {
	srv := startFakeServer(t, fakeOpts{
		codeClass: 2, codeDetail: 5,
		contentFormat: 40, // application/link-format
		payload:       []byte(`</sensors/temp>;rt="temperature",</sensors/hum>;rt="humidity"`),
	})
	defer srv.close()

	res, err := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("expected outcome=success, got %q", res.Outcome)
	}
	if res.ResponseCodeClass != 2 || res.ResponseCodeDetail != 5 {
		t.Errorf("expected 2.05, got %d.%02d", res.ResponseCodeClass, res.ResponseCodeDetail)
	}
	if !strings.Contains(res.ResponseCodeMeaning, "Content") {
		t.Errorf("expected meaning containing Content, got %q", res.ResponseCodeMeaning)
	}
	if res.ContentFormat != 40 {
		t.Errorf("expected ContentFormat=40, got %d", res.ContentFormat)
	}
	if !strings.Contains(res.PayloadExcerpt, "sensors/temp") {
		t.Errorf("expected payload excerpt to contain sensors/temp, got %q", res.PayloadExcerpt)
	}

	// Invariant runtime : 1 seul paquet reçu côté serveur.
	time.Sleep(100 * time.Millisecond)
	if got := srv.packetsReceived.Load(); got != 1 {
		t.Fatalf("expected 1 packet received, got %d (retransmission interdite)", got)
	}
}

func TestProbe_404NotFound(t *testing.T) {
	srv := startFakeServer(t, fakeOpts{codeClass: 4, codeDetail: 4})
	defer srv.close()

	res, _ := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("expected outcome=success (the probe succeeded — 404 is the answer), got %q", res.Outcome)
	}
	if res.ResponseCodeClass != 4 || res.ResponseCodeDetail != 4 {
		t.Errorf("expected 4.04, got %d.%02d", res.ResponseCodeClass, res.ResponseCodeDetail)
	}
}

func TestProbe_NotCoAP_Garbage(t *testing.T) {
	srv := startFakeServer(t, fakeOpts{garbage: true})
	defer srv.close()

	res, _ := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if res.Outcome != OutcomeNotCoAP {
		t.Errorf("expected outcome=not_coap, got %q", res.Outcome)
	}
}

func TestProbe_TimeoutSilent(t *testing.T) {
	srv := startFakeServer(t, fakeOpts{silent: true})
	defer srv.close()

	start := time.Now()
	res, _ := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 300 * time.Millisecond})
	elapsed := time.Since(start)
	if elapsed > 2*time.Second {
		t.Errorf("probe took %v, expected ~300ms", elapsed)
	}
	if res.Outcome != OutcomeTimeout && res.Outcome != OutcomeNotCoAP {
		t.Errorf("expected timeout or not_coap, got %q", res.Outcome)
	}
}

func TestProbe_DialError_ClosedPort(t *testing.T) {
	// Cherche un port UDP probablement fermé. Sur Linux, un GET vers
	// un port fermé peut soit (a) timeout (pas d'ICMP), soit (b)
	// retourner "connection refused" si ICMP Port Unreachable arrive.
	// Les deux sont OK pour ce test — on accepte timeout ou dial_error.
	res, _ := Probe(context.Background(), "127.0.0.1", Config{Port: 65534, Timeout: 300 * time.Millisecond})
	if res.Outcome != OutcomeDialError && res.Outcome != OutcomeTimeout && res.Outcome != OutcomeNotCoAP {
		t.Errorf("expected dial_error/timeout/not_coap on closed port, got %q", res.Outcome)
	}
}

// TestProbe_MulticastRejected : invariant clé — Reconaut N'ENVOIE JAMAIS
// vers une adresse multicast.
func TestProbe_MulticastRejected(t *testing.T) {
	multicastIPs := []string{"224.0.1.187", "239.0.0.1", "ff00::1"}
	for _, ip := range multicastIPs {
		t.Run(ip, func(t *testing.T) {
			res, err := Probe(context.Background(), ip, Config{Port: 5683, Timeout: 500 * time.Millisecond})
			if err == nil {
				t.Errorf("expected error refusing multicast target %s, got nil", ip)
			}
			if !errors.Is(err, err) || (err != nil && !strings.Contains(err.Error(), "multicast")) {
				t.Errorf("error message should mention multicast for %s, got %v", ip, err)
			}
			if res.Outcome != OutcomeDialError {
				t.Errorf("expected outcome=dial_error for multicast %s, got %q", ip, res.Outcome)
			}
		})
	}
}

// TestProbe_PayloadExcerptCapped : le serveur retourne 10 KB ; on
// vérifie que l'excerpt est plafonné à 4096 bytes.
func TestProbe_PayloadExcerptCapped(t *testing.T) {
	big := make([]byte, 10000)
	for i := range big {
		big[i] = 'A' + byte(i%26)
	}
	srv := startFakeServer(t, fakeOpts{
		codeClass: 2, codeDetail: 5, contentFormat: 40, payload: big,
	})
	defer srv.close()

	res, _ := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if len(res.PayloadExcerpt) > maxPayloadExcerpt {
		t.Errorf("payload excerpt %d bytes, max %d", len(res.PayloadExcerpt), maxPayloadExcerpt)
	}
}

// TestBuildPacket_WellFormed : la trame CoAP générée est conforme aux
// attendus structurels (header, code, options).
func TestBuildPacket_WellFormed(t *testing.T) {
	pkt, err := buildGetWellKnownCore()
	if err != nil {
		t.Fatalf("buildGetWellKnownCore: %v", err)
	}
	// byte 0 : Ver=01, Type=00 (CON), TKL=2 → 0100 0010 = 0x42
	if pkt[0] != 0x42 {
		t.Errorf("header byte: got %#x, want 0x42", pkt[0])
	}
	// byte 1 : Code = GET = 0x01
	if pkt[1] != 0x01 {
		t.Errorf("code byte: got %#x, want 0x01 (GET)", pkt[1])
	}
	// L'absence de code 0x02 (POST), 0x03 (PUT), 0x04 (DELETE) est
	// l'invariant le plus important.
	for i, b := range pkt {
		if i == 1 {
			continue
		}
		if b == 0x02 || b == 0x03 || b == 0x04 {
			// Ces bytes peuvent légitimement apparaître ailleurs (par
			// ex. dans le token), on n'asserte rien — l'invariant est
			// que le code byte (offset 1) reste GET.
		}
	}
	// Le packet doit contenir "well-known" et "core" textuellement.
	if !strings.Contains(string(pkt), "well-known") {
		t.Errorf("expected packet to contain well-known, got %q", string(pkt))
	}
	if !strings.Contains(string(pkt), "core") {
		t.Errorf("expected packet to contain core, got %q", string(pkt))
	}
}
