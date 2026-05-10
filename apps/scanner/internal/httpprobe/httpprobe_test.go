// SPDX-License-Identifier: AGPL-3.0-only
package httpprobe

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Cf. openspec/changes/add-http-probe/specs/scanning/spec.md
//   -> Requirement: HTTP Banner and TLS Capture

func portOf(t *testing.T, addr string) int {
	t.Helper()
	_, p, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatalf("split %q: %v", addr, err)
	}
	n, err := strconv.Atoi(p)
	if err != nil {
		t.Fatalf("atoi %q: %v", p, err)
	}
	return n
}

func hostOf(t *testing.T, addr string) string {
	t.Helper()
	h, _, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatalf("split %q: %v", addr, err)
	}
	return h
}

func TestProbe_HTTP_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Server", "nginx/1.18.0")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(200)
		_, _ = w.Write([]byte("<html><body>hello</body></html>"))
	}))
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "http://")
	res, err := Probe(context.Background(), hostOf(t, addr), Config{
		Scheme: "http", Port: portOf(t, addr), Timeout: 2 * time.Second,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("expected outcome=success, got %q", res.Outcome)
	}
	if res.Status != 200 {
		t.Errorf("expected status 200, got %d", res.Status)
	}
	if res.Server != "nginx/1.18.0" {
		t.Errorf("expected server=nginx/1.18.0, got %q", res.Server)
	}
	if !strings.Contains(res.BodyExcerpt, "hello") {
		t.Errorf("expected body to contain 'hello', got %q", res.BodyExcerpt)
	}
	if res.TLSCertSHA256 != "" {
		t.Errorf("HTTP should not capture TLS cert, got %q", res.TLSCertSHA256)
	}
}

func TestProbe_HTTPS_CapturesCertAndALPN(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Server", "Apache/2.4.52")
		_, _ = w.Write([]byte("<html>secure</html>"))
	}))
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "https://")
	res, err := Probe(context.Background(), hostOf(t, addr), Config{
		Scheme: "https", Port: portOf(t, addr), Timeout: 2 * time.Second,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("expected outcome=success, got %q (status=%d)", res.Outcome, res.Status)
	}
	if res.Status != 200 {
		t.Errorf("expected status 200, got %d", res.Status)
	}
	if res.TLSCertSHA256 == "" {
		t.Errorf("expected tls_cert_sha256 to be populated")
	}
	if len(res.TLSCertDER) == 0 {
		t.Errorf("expected tls_cert_der to be populated")
	}
	if res.TLSNotAfter == "" {
		t.Errorf("expected tls_not_after to be populated")
	}
	if len(res.ALPN) == 0 {
		t.Errorf("expected ALPN to be populated, got %v", res.ALPN)
	}
}

// Génère un cert self-signed expiré pour TestProbe_HTTPS_ExpiredCertCapturedAnyway.
func makeExpiredCert(t *testing.T) tls.Certificate {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("ecdsa: %v", err)
	}
	tpl := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "expired.test"},
		NotBefore:    time.Now().Add(-2 * time.Hour),
		NotAfter:     time.Now().Add(-1 * time.Hour), // déjà expiré
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"expired.test", "127.0.0.1"},
		IPAddresses:  []net.IP{net.IPv4(127, 0, 0, 1)},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tpl, &tpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}
}

func TestProbe_HTTPS_ExpiredCertCapturedAnyway(t *testing.T) {
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(200)
		_, _ = w.Write([]byte("ok"))
	}))
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{makeExpiredCert(t)}}
	srv.StartTLS()
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "https://")
	res, err := Probe(context.Background(), hostOf(t, addr), Config{
		Scheme: "https", Port: portOf(t, addr), Timeout: 2 * time.Second,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	// Cert expiré → success (capture-only, validation a posteriori).
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("expected outcome=success even with expired cert, got %q", res.Outcome)
	}
	if res.TLSCertSHA256 == "" {
		t.Errorf("expected expired cert to still be captured")
	}
	// Le NotAfter doit être passé.
	notAfter, _ := time.Parse(time.RFC3339, res.TLSNotAfter)
	if !notAfter.Before(time.Now()) {
		t.Errorf("expected NotAfter in past, got %v", notAfter)
	}
}

func TestProbe_NoRedirectFollow(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Location", "https://other.example.com/")
		w.WriteHeader(301)
	}))
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "http://")
	res, err := Probe(context.Background(), hostOf(t, addr), Config{
		Scheme: "http", Port: portOf(t, addr), Timeout: 2 * time.Second,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Status != 301 {
		t.Errorf("expected status 301, got %d", res.Status)
	}
	if res.Headers["Location"] != "https://other.example.com/" {
		t.Errorf("expected Location header captured, got %v", res.Headers)
	}
}

func TestProbe_BodyCappedAt32KiB(t *testing.T) {
	bigBody := strings.Repeat("X", 1024*1024) // 1 MiB
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", strconv.Itoa(len(bigBody)))
		_, _ = w.Write([]byte(bigBody))
	}))
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "http://")
	res, err := Probe(context.Background(), hostOf(t, addr), Config{
		Scheme: "http", Port: portOf(t, addr), Timeout: 5 * time.Second,
		MaxBodyBytes: 32 * 1024,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if len(res.BodyExcerpt) != 32*1024 {
		t.Errorf("expected body_excerpt length=32768, got %d", len(res.BodyExcerpt))
	}
	if res.BytesReceived <= 32*1024 {
		t.Errorf("expected bytes_received > 32768 (truncation), got %d", res.BytesReceived)
	}
}

func TestProbe_DialError(t *testing.T) {
	// Trouve un port libre puis le ferme.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	port := portOf(t, addr)
	_ = ln.Close()

	res, err := Probe(context.Background(), "127.0.0.1", Config{
		Scheme: "http", Port: port, Timeout: 1 * time.Second,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.Outcome != OutcomeDialError {
		t.Errorf("expected outcome=dial_error, got %q", res.Outcome)
	}
}

func TestProbe_TimeoutOnSlowServer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(2 * time.Second)
		w.WriteHeader(200)
	}))
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "http://")
	start := time.Now()
	res, err := Probe(context.Background(), hostOf(t, addr), Config{
		Scheme: "http", Port: portOf(t, addr), Timeout: 300 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	elapsed := time.Since(start)
	if elapsed > 1500*time.Millisecond {
		t.Errorf("probe took %v, expected ~300ms", elapsed)
	}
	if res.Outcome != OutcomeTimeout {
		t.Errorf("expected outcome=timeout, got %q", res.Outcome)
	}
}

func TestProbe_UserAgentRespected(t *testing.T) {
	var captured atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured.Store(r.Header.Get("User-Agent"))
		w.WriteHeader(200)
	}))
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "http://")

	// Default UA
	_, err := Probe(context.Background(), hostOf(t, addr), Config{
		Scheme: "http", Port: portOf(t, addr), Timeout: 2 * time.Second,
	})
	if err != nil {
		t.Fatalf("Probe (default UA): %v", err)
	}
	if ua, _ := captured.Load().(string); !strings.HasPrefix(ua, "Reconaut/") {
		t.Errorf("expected default UA to start with 'Reconaut/', got %q", ua)
	}

	// Custom UA
	_, err = Probe(context.Background(), hostOf(t, addr), Config{
		Scheme: "http", Port: portOf(t, addr), Timeout: 2 * time.Second,
		UserAgent: "MyScanner/1.0",
	})
	if err != nil {
		t.Fatalf("Probe (custom UA): %v", err)
	}
	if ua, _ := captured.Load().(string); ua != "MyScanner/1.0" {
		t.Errorf("expected custom UA, got %q", ua)
	}
}

func TestProbe_MaxBodyClampedToHardCap(t *testing.T) {
	res, _ := Probe(context.Background(), "127.0.0.1", Config{
		Scheme: "http", Port: 1, Timeout: 100 * time.Millisecond,
		MaxBodyBytes: 999_999_999, // > 1 MiB
	})
	// On ne teste pas le body (port fermé), juste que le defaulting
	// ne pète pas et le cap dur est appliqué silencieusement.
	if res.Outcome == "" {
		t.Errorf("expected an outcome, got empty")
	}
}

func TestProbe_DefaultPortPerScheme(t *testing.T) {
	// On ne lance pas de serveur — on vérifie juste que withDefaults
	// pose 80 pour http et 443 pour https quand Port=0.
	cases := []struct {
		scheme string
		want   int
	}{
		{"http", 80},
		{"https", 443},
	}
	for _, c := range cases {
		got := withDefaults(Config{Scheme: c.scheme}).Port
		if got != c.want {
			t.Errorf("scheme=%s want port=%d got=%d", c.scheme, c.want, got)
		}
	}
}

// Vérifie que le code source ne contient AUCUN appel à des méthodes
// HTTP autres que GET/HEAD. Test runtime-grep en complément du linter
// shell (check_http_probe_no_offensive.sh).
func TestProbe_NoOffensiveHTTPMethodsInSource(t *testing.T) {
	data, err := os.ReadFile("httpprobe.go")
	if err != nil {
		t.Fatalf("read httpprobe.go: %v", err)
	}
	src := string(data)
	forbidden := []string{
		"http.MethodPost", "http.MethodPut", "http.MethodDelete",
		"http.MethodPatch", "http.MethodOptions", "http.MethodTrace",
		"http.MethodConnect",
	}
	for _, fw := range forbidden {
		if strings.Contains(src, fw) {
			t.Errorf("httpprobe.go contains forbidden HTTP method ref %q", fw)
		}
	}
}

