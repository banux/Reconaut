// SPDX-License-Identifier: AGPL-3.0-only
package modbusprobe

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeModbusServer écoute en TCP local et répond à chaque MBAP+PDU reçu
// selon un script. Compte les paquets reçus sur la connexion ; le test
// échoue si > 2.
type fakeModbusServer struct {
	listener net.Listener
	t        *testing.T
	wg       sync.WaitGroup

	// Scenarios : la séquence de responses à émettre, une par paquet reçu.
	responses [][]byte
	silent    bool
	garbage   bool

	packetsReceived atomic.Int64
}

type fakeOpts struct {
	responses [][]byte // séquence de réponses (1er request → 1er resp, etc.)
	silent    bool
	garbage   bool
}

func startFakeServer(t *testing.T, opts fakeOpts) *fakeModbusServer {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	s := &fakeModbusServer{
		listener:  ln,
		t:         t,
		responses: opts.responses,
		silent:    opts.silent,
		garbage:   opts.garbage,
	}
	s.wg.Add(1)
	go s.acceptLoop()
	return s
}

func (s *fakeModbusServer) acceptLoop() {
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

func (s *fakeModbusServer) handleConn(conn net.Conn) {
	defer s.wg.Done()
	defer conn.Close()

	if s.silent {
		buf := make([]byte, 1024)
		_, _ = conn.Read(buf)
		return
	}
	if s.garbage {
		_, _ = conn.Write([]byte("HTTP/1.1 200 OK\r\n\r\nnope"))
		return
	}

	respIdx := 0
	for {
		_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		// Lire MBAP header (7 bytes)
		mbap := make([]byte, 7)
		if _, err := io.ReadFull(conn, mbap); err != nil {
			return
		}
		// Length = unit_id (1) + PDU bytes
		bodyLen := int(binary.BigEndian.Uint16(mbap[4:6])) - 1
		if bodyLen <= 0 || bodyLen > 253 {
			return
		}
		pdu := make([]byte, bodyLen)
		if _, err := io.ReadFull(conn, pdu); err != nil {
			return
		}
		s.packetsReceived.Add(1)

		// Si > 2 paquets, c'est une violation du contrat.
		if s.packetsReceived.Load() > 2 {
			s.t.Errorf("modbusprobe sent > 2 packets per connection (got %d)", s.packetsReceived.Load())
			return
		}

		if respIdx >= len(s.responses) {
			return
		}
		// Construire le MBAP de réponse (echo transaction_id + protocol_id).
		respPdu := s.responses[respIdx]
		respIdx++
		respMBAP := make([]byte, 7)
		copy(respMBAP[0:4], mbap[0:4]) // echo transaction_id + protocol_id
		binary.BigEndian.PutUint16(respMBAP[4:6], uint16(len(respPdu)+1))
		respMBAP[6] = mbap[6] // echo unit_id
		full := append(respMBAP, respPdu...)
		if _, err := conn.Write(full); err != nil {
			return
		}
	}
}

func (s *fakeModbusServer) addr() string { return s.listener.Addr().String() }
func (s *fakeModbusServer) host() string { h, _, _ := net.SplitHostPort(s.addr()); return h }
func (s *fakeModbusServer) port() int {
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
func (s *fakeModbusServer) close() {
	_ = s.listener.Close()
	s.wg.Wait()
}

// ----------------- Fixtures de réponses Modbus -----------------

// readDeviceIDSuccess construit un PDU de réponse Read Device ID positive :
//
//	[0x2B][mei_type=0x0E][read_device_id_code=0x01][conformity=0x01]
//	[more_follows=0x00][next_object_id=0x00][number_of_objects=N]
//	pour chaque objet : [object_id][len][value...]
func readDeviceIDSuccess(vendor, product, revision string) []byte {
	pdu := []byte{
		fnReadDeviceID, meiTypeReadDeviceID,
		0x01, // read_device_id_code = basic
		0x01, // conformity_level
		0x00, // more_follows = no
		0x00, // next_object_id
		0x03, // number_of_objects
	}
	for i, v := range []string{vendor, product, revision} {
		pdu = append(pdu, byte(i), byte(len(v)))
		pdu = append(pdu, []byte(v)...)
	}
	return pdu
}

// readDeviceIDException : exception 0x01 "Illegal Function" sur 0x2B.
func readDeviceIDException(exCode byte) []byte {
	return []byte{fnReadDeviceID | exceptionMask, exCode}
}

// readHoldingSuccess : réponse minimale à fn=0x03 avec 1 registre.
func readHoldingSuccess() []byte {
	return []byte{fnReadHoldingRegisters, 0x02, 0x12, 0x34} // byte_count=2, value=0x1234
}

// readHoldingException : exception 0x02 sur 0x03.
func readHoldingException(exCode byte) []byte {
	return []byte{fnReadHoldingRegisters | exceptionMask, exCode}
}

// ----------------- TESTS -----------------

func TestProbe_ReadDeviceIDSuccess(t *testing.T) {
	srv := startFakeServer(t, fakeOpts{
		responses: [][]byte{readDeviceIDSuccess("Schneider Electric", "BMENOC0301", "2.10")},
	})
	defer srv.close()

	res, err := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("outcome: got %q, want success", res.Outcome)
	}
	if res.VendorName != "Schneider Electric" {
		t.Errorf("vendor: got %q", res.VendorName)
	}
	if res.ProductCode != "BMENOC0301" {
		t.Errorf("product: got %q", res.ProductCode)
	}
	if res.MajorMinorRevision != "2.10" {
		t.Errorf("revision: got %q", res.MajorMinorRevision)
	}
	if res.FunctionCode != 0x2B {
		t.Errorf("function_code: got %#x", res.FunctionCode)
	}
	if !res.IsModbus {
		t.Errorf("is_modbus should be true")
	}
	// Invariant clé : exactement 1 paquet envoyé (pas de fallback nécessaire).
	time.Sleep(100 * time.Millisecond)
	if got := srv.packetsReceived.Load(); got != 1 {
		t.Fatalf("expected 1 packet, got %d", got)
	}
}

func TestProbe_ReadDeviceIDException_FallbackReadHoldingSuccess(t *testing.T) {
	srv := startFakeServer(t, fakeOpts{
		responses: [][]byte{
			readDeviceIDException(0x01), // Illegal Function sur 0x2B
			readHoldingSuccess(),
		},
	})
	defer srv.close()

	res, err := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("outcome: got %q, want success", res.Outcome)
	}
	if !res.IsModbus {
		t.Errorf("is_modbus should be true (fallback succeeded)")
	}
	if res.FunctionCode != 0x03 {
		t.Errorf("function_code: expected 0x03 (Read Holding fallback), got %#x", res.FunctionCode)
	}
	if res.VendorName != "" || res.ProductCode != "" {
		t.Errorf("vendor/product should be empty when fallback used: %+v", res)
	}
	// Invariant clé : exactement 2 paquets envoyés (le seuil max).
	time.Sleep(100 * time.Millisecond)
	if got := srv.packetsReceived.Load(); got != 2 {
		t.Fatalf("expected 2 packets, got %d", got)
	}
}

func TestProbe_BothFunctionsException(t *testing.T) {
	srv := startFakeServer(t, fakeOpts{
		responses: [][]byte{
			readDeviceIDException(0x01),
			readHoldingException(0x02),
		},
	})
	defer srv.close()

	res, _ := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("outcome: got %q, want success (is_modbus suffit)", res.Outcome)
	}
	if !res.IsModbus {
		t.Errorf("is_modbus should be true (exception reçue = endpoint Modbus)")
	}
	if res.ExceptionCode == 0 {
		t.Errorf("exception_code should be non-zero")
	}
}

func TestProbe_NotModbus_Garbage(t *testing.T) {
	srv := startFakeServer(t, fakeOpts{garbage: true})
	defer srv.close()

	res, _ := Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	if res.Outcome != OutcomeNotModbus {
		t.Errorf("outcome: got %q, want not_modbus", res.Outcome)
	}
	if res.IsModbus {
		t.Errorf("is_modbus should be false on garbage response")
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
	if res.Outcome != OutcomeTimeout && res.Outcome != OutcomeNotModbus {
		t.Errorf("outcome: got %q, want timeout or not_modbus", res.Outcome)
	}
}

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
		t.Errorf("outcome: got %q, want dial_error", res.Outcome)
	}
}

func TestProbe_AtMostTwoPackets(t *testing.T) {
	// Scénario où le serveur scripte 5 réponses (delibérément trop) — on
	// vérifie que le sondeur n'en consomme jamais plus de 2.
	srv := startFakeServer(t, fakeOpts{
		responses: [][]byte{
			readDeviceIDException(0x01),
			readHoldingException(0x02),
			[]byte{0x03, 0x02, 0xAA, 0xBB}, // serait fn=0x03 success mais pas demandé
			[]byte{0x2B, 0x0E, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 'X'}, // pareil
			[]byte{0x03, 0x02, 0xCC, 0xDD},
		},
	})
	defer srv.close()

	_, _ = Probe(context.Background(), srv.host(), Config{Port: srv.port(), Timeout: 1 * time.Second})
	time.Sleep(150 * time.Millisecond)

	got := srv.packetsReceived.Load()
	if got > 2 {
		t.Fatalf("modbusprobe sent %d packets, MUST be ≤ 2", got)
	}
}

// TestBuildReadDeviceID_Wellformed : la trame envoyée a la forme attendue.
func TestBuildReadDeviceID_Wellformed(t *testing.T) {
	pkt := buildReadDeviceID(0x01)
	if len(pkt) != 11 {
		t.Fatalf("packet length: got %d, want 11 (MBAP 7 + PDU 4)", len(pkt))
	}
	// MBAP[2..4] : protocol_id = 0
	if pkt[2] != 0 || pkt[3] != 0 {
		t.Errorf("protocol_id should be 0, got %#x %#x", pkt[2], pkt[3])
	}
	// MBAP[6] : unit_id = 0x01
	if pkt[6] != 0x01 {
		t.Errorf("unit_id: got %#x, want 0x01", pkt[6])
	}
	// PDU[0] : function_code = 0x2B
	if pkt[7] != fnReadDeviceID {
		t.Errorf("function_code: got %#x, want %#x", pkt[7], fnReadDeviceID)
	}
	// PDU[1] : mei_type = 0x0E
	if pkt[8] != meiTypeReadDeviceID {
		t.Errorf("mei_type: got %#x, want %#x", pkt[8], meiTypeReadDeviceID)
	}
}

// TestBuildReadHoldingRegisters_ReadOnly : la trame fallback est bien
// une fonction READ (0x03), pas une fonction WRITE.
func TestBuildReadHoldingRegisters_ReadOnly(t *testing.T) {
	pkt := buildReadHoldingRegisters(0x01)
	if pkt[7] != fnReadHoldingRegisters {
		t.Errorf("function_code: got %#x, want %#x (Read Holding Registers)", pkt[7], fnReadHoldingRegisters)
	}
	// Invariant critique : la fonction NE DOIT PAS être une write.
	writeFns := []byte{0x05, 0x06, 0x0F, 0x10, 0x17, 0x08}
	for _, fn := range writeFns {
		if pkt[7] == fn {
			t.Fatalf("FORBIDDEN function code %#x detected", fn)
		}
	}
}

// TestDecodeException : table des codes standards.
func TestDecodeException(t *testing.T) {
	cases := map[byte]string{
		0x01: "Illegal Function",
		0x02: "Illegal Data Address",
		0x03: "Illegal Data Value",
		0x06: "Server Device Busy",
		0xFF: "Unknown Exception",
	}
	for code, want := range cases {
		got := decodeException(code)
		if !strings.Contains(got, want) {
			t.Errorf("decodeException(%#x): got %q, want substring %q", code, got, want)
		}
	}
}
