package dnsprobe

import (
	"context"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// Fake DNS server local utilisé par les tests. Démarre sur un port
// éphémère (UDP 127.0.0.1:0), expose le handler choisi, retourne le
// addr et un closer.
//
// Cf. openspec/changes/add-dns-records-scanner/specs/scanning/spec.md
// (Scenario: Résolveur configuré pointe un Unbound interne).

type fakeServer struct {
	addr   string
	server *dns.Server
	wg     sync.WaitGroup
	mu     sync.Mutex
	// queries enregistre les types interrogés (pour assert qu'AXFR
	// n'est jamais demandé).
	queries []uint16
}

func startFakeServer(t *testing.T, handler dns.HandlerFunc) *fakeServer {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen udp: %v", err)
	}
	addr := pc.LocalAddr().String()
	fs := &fakeServer{addr: addr}
	wrap := dns.HandlerFunc(func(w dns.ResponseWriter, r *dns.Msg) {
		fs.mu.Lock()
		for _, q := range r.Question {
			fs.queries = append(fs.queries, q.Qtype)
		}
		fs.mu.Unlock()
		handler(w, r)
	})
	srv := &dns.Server{PacketConn: pc, Handler: wrap}
	fs.server = srv
	fs.wg.Add(1)
	go func() {
		defer fs.wg.Done()
		_ = srv.ActivateAndServe()
	}()
	t.Cleanup(func() {
		_ = srv.Shutdown()
		fs.wg.Wait()
	})
	// Tiny grace period for the server to be ready.
	time.Sleep(20 * time.Millisecond)
	return fs
}

func (fs *fakeServer) snapshotQueries() []uint16 {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	out := make([]uint16, len(fs.queries))
	copy(out, fs.queries)
	return out
}

func TestResolve_HappyPath(t *testing.T) {
	handler := dns.HandlerFunc(func(w dns.ResponseWriter, r *dns.Msg) {
		m := new(dns.Msg)
		m.SetReply(r)
		q := r.Question[0]
		switch q.Qtype {
		case dns.TypeA:
			rr, _ := dns.NewRR("example.fr. 300 IN A 192.0.2.10")
			m.Answer = append(m.Answer, rr)
		case dns.TypeAAAA:
			rr, _ := dns.NewRR("example.fr. 300 IN AAAA 2001:db8::1")
			m.Answer = append(m.Answer, rr)
		case dns.TypeMX:
			rr, _ := dns.NewRR("example.fr. 300 IN MX 10 mail.example.fr.")
			m.Answer = append(m.Answer, rr)
		case dns.TypeNS:
			rr, _ := dns.NewRR("example.fr. 300 IN NS ns1.example.fr.")
			m.Answer = append(m.Answer, rr)
		case dns.TypeTXT:
			rr, _ := dns.NewRR(`example.fr. 300 IN TXT "v=spf1 -all"`)
			m.Answer = append(m.Answer, rr)
		case dns.TypeCAA:
			rr, _ := dns.NewRR(`example.fr. 300 IN CAA 0 issue "letsencrypt.org"`)
			m.Answer = append(m.Answer, rr)
		case dns.TypeSOA:
			rr, _ := dns.NewRR("example.fr. 300 IN SOA ns1.example.fr. hostmaster.example.fr. 2026050801 7200 3600 1209600 3600")
			m.Answer = append(m.Answer, rr)
		case dns.TypeCNAME:
			// Pas de CNAME pour l'apex, c'est normal.
		}
		_ = w.WriteMsg(m)
	})
	fs := startFakeServer(t, handler)

	out, err := Resolve(context.Background(), "example.fr", Config{
		Resolver: fs.addr,
		Timeout:  500 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if len(out.Records) < 7 {
		t.Fatalf("expected ≥7 records (A,AAAA,MX,NS,TXT,CAA,SOA), got %d : %+v", len(out.Records), out.Records)
	}

	gotTypes := make(map[string]int)
	for _, r := range out.Records {
		gotTypes[r.RecordType]++
	}
	for _, want := range []string{"A", "AAAA", "MX", "NS", "TXT", "CAA", "SOA"} {
		if gotTypes[want] == 0 {
			t.Errorf("missing record type %s in result", want)
		}
	}

	mxRecord := findRecord(out.Records, "MX")
	if !strings.Contains(mxRecord.Value, "mail.example.fr") {
		t.Errorf("MX value = %q, want it to contain mail.example.fr", mxRecord.Value)
	}
}

func TestResolve_NeverQueriesAXFR(t *testing.T) {
	handler := dns.HandlerFunc(func(w dns.ResponseWriter, r *dns.Msg) {
		m := new(dns.Msg)
		m.SetReply(r)
		_ = w.WriteMsg(m) // empty reply
	})
	fs := startFakeServer(t, handler)

	_, err := Resolve(context.Background(), "example.fr", Config{
		Resolver: fs.addr,
		Timeout:  300 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}

	for _, qt := range fs.snapshotQueries() {
		if qt == dns.TypeAXFR || qt == dns.TypeIXFR {
			t.Errorf("forbidden zone transfer query observed (qtype=%d)", qt)
		}
	}
}

func TestResolve_TimeoutPerType_DoesNotBlockOthers(t *testing.T) {
	// Le serveur répond seulement aux types pairs, et ne répond
	// jamais aux types impairs (simule un timeout par type).
	handler := dns.HandlerFunc(func(w dns.ResponseWriter, r *dns.Msg) {
		q := r.Question[0]
		// Drop la requête pour MX (15) : pas de reply -> timeout.
		if q.Qtype == dns.TypeMX {
			return
		}
		m := new(dns.Msg)
		m.SetReply(r)
		switch q.Qtype {
		case dns.TypeA:
			rr, _ := dns.NewRR("ex.fr. 60 IN A 198.51.100.1")
			m.Answer = append(m.Answer, rr)
		case dns.TypeNS:
			rr, _ := dns.NewRR("ex.fr. 60 IN NS ns.ex.fr.")
			m.Answer = append(m.Answer, rr)
		}
		_ = w.WriteMsg(m)
	})
	fs := startFakeServer(t, handler)

	start := time.Now()
	out, err := Resolve(context.Background(), "ex.fr", Config{
		Resolver: fs.addr,
		Timeout:  150 * time.Millisecond,
		Types:    []string{"A", "MX", "NS"},
	})
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}

	// MX a timeout, A et NS ont répondu.
	if !contains(out.FailedTypes, "MX") {
		t.Errorf("MX should be in FailedTypes : %v", out.FailedTypes)
	}
	if findRecord(out.Records, "A").Value == "" {
		t.Errorf("A record should be present despite MX timeout")
	}
	if findRecord(out.Records, "NS").Value == "" {
		t.Errorf("NS record should be present despite MX timeout")
	}

	// Le timeout MX n'a pas bloqué l'ensemble : on doit avoir terminé
	// en moins de 3× le timeout.
	if elapsed > 3*150*time.Millisecond+200*time.Millisecond {
		t.Errorf("Resolve took too long (%s) ; timeout per type not respected", elapsed)
	}
}

func TestResolve_RejectsForbiddenType(t *testing.T) {
	_, err := Resolve(context.Background(), "ex.fr", Config{
		Resolver: "127.0.0.1:53",
		Types:    []string{"A", "AXFR"},
	})
	if err == nil {
		t.Fatal("expected error when AXFR is in Types")
	}
	if !strings.Contains(err.Error(), "AXFR") {
		t.Errorf("error should mention AXFR : %v", err)
	}
}

func TestResolve_RejectsEmptyTarget(t *testing.T) {
	_, err := Resolve(context.Background(), "  ", Config{Resolver: "127.0.0.1:53"})
	if err == nil {
		t.Fatal("expected error on empty target")
	}
}

func findRecord(records []Record, typeName string) Record {
	for _, r := range records {
		if r.RecordType == typeName {
			return r
		}
	}
	return Record{}
}

func contains(haystack []string, needle string) bool {
	for _, v := range haystack {
		if v == needle {
			return true
		}
	}
	return false
}
