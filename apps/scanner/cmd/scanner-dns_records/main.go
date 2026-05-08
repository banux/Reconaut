// scanner-dns_records : binaire spécialisé `scan:dns_records`. Cf.
// openspec/changes/add-dns-records-scanner/specs/architecture/spec.md.
//
// Le binaire résout les enregistrements DNS (A, AAAA, MX, NS, TXT,
// CAA, SOA, CNAME) d'un domaine ou d'un host couvert par le scope
// déclaré côté Rails. Pas d'AXFR ni d'IXFR — le scanner émet une
// requête par type, jamais de zone transfer.
//
// Variables d'environnement :
//   - RECONAUT_DNS_RESOLVER : "host:port" du résolveur cible (défaut
//     = résolveur système lu depuis /etc/resolv.conf).
//   - RECONAUT_DNS_TIMEOUT  : timeout par requête en secondes (défaut 5).
package main

import (
	"context"
	"os"
	"strconv"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/dnsprobe"
	"github.com/banux/Reconaut/apps/scanner/internal/runtime"
	"github.com/banux/Reconaut/apps/scanner/internal/scanhandler"
)

func main() {
	timeoutSec := 5
	if v := os.Getenv("RECONAUT_DNS_TIMEOUT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			timeoutSec = n
		}
	}
	cfg := dnsprobe.Config{
		Resolver: os.Getenv("RECONAUT_DNS_RESOLVER"),
		Timeout:  time.Duration(timeoutSec) * time.Second,
	}

	prober := dnsProber{cfg: cfg}

	os.Exit(runtime.Run(runtime.Config{
		ScanKind: "dns_records",
		Args:     os.Args[1:],
		HandlerOptions: scanhandler.Options{
			DNSProber: prober,
		},
	}))
}

// dnsProber adapte dnsprobe.Resolve à l'interface scanhandler.DNSProber
// (mappe dnsprobe.Record → scanhandler.ResolvedRecord).
type dnsProber struct {
	cfg dnsprobe.Config
}

func (p dnsProber) Resolve(ctx context.Context, target string) ([]scanhandler.ResolvedRecord, error) {
	out, err := dnsprobe.Resolve(ctx, target, p.cfg)
	if err != nil {
		return nil, err
	}
	mapped := make([]scanhandler.ResolvedRecord, 0, len(out.Records))
	for _, r := range out.Records {
		mapped = append(mapped, scanhandler.ResolvedRecord{
			RecordType: r.RecordType,
			Name:       r.Name,
			Value:      r.Value,
			TTL:        r.TTL,
		})
	}
	return mapped, nil
}
