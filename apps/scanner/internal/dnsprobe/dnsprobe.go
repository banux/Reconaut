// SPDX-License-Identifier: AGPL-3.0-only
// Package dnsprobe résout les enregistrements DNS d'un domaine ou
// d'un host.
//
// Source de vérité :
//
//	openspec/changes/add-dns-records-scanner/specs/scanning/spec.md
//	  -> Requirement: DNS Records Resolution Scanner
//
// Le package émet une requête DNS par type listé dans Config.Types.
// JAMAIS de zone transfer (AXFR/IXFR) — c'est offensif et utile à
// rien contre les résolveurs publics modernes. Le linter de §5.3
// vérifie qu'aucune mention "AXFR" ou "IXFR" n'apparaît dans ce
// fichier hors commentaire « interdit ».
//
// Le résolveur est configurable (Config.Resolver = "host:port") pour
// permettre à un opérateur de pointer un Unbound interne plutôt que
// le résolveur système.
package dnsprobe

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/miekg/dns"
)

// DefaultTypes est l'ensemble par défaut des types résolus pour un
// scan dns_records. Le champ CAA et SOA exigent une lib DNS qui parse
// au-delà de net.Resolver — d'où la dépendance à miekg/dns (BSD-3,
// compatible AGPL).
var DefaultTypes = []string{"A", "AAAA", "MX", "NS", "TXT", "CAA", "SOA", "CNAME"}

// AllowedTypes est la whitelist des types interrogeables. Les types
// listés correspondent à des records publics légitimes ; AXFR et IXFR
// (zone transfer) sont délibérément absents — c'est offensif et
// rejeté par construction par ce package.
var AllowedTypes = map[string]uint16{
	"A":     dns.TypeA,
	"AAAA":  dns.TypeAAAA,
	"MX":    dns.TypeMX,
	"NS":    dns.TypeNS,
	"TXT":   dns.TypeTXT,
	"CAA":   dns.TypeCAA,
	"SOA":   dns.TypeSOA,
	"CNAME": dns.TypeCNAME,
}

// Config paramètre la résolution.
type Config struct {
	// Resolver : "host:port" (ex: "127.0.0.1:53"). Vide → résolveur
	// système (lecture de /etc/resolv.conf).
	Resolver string
	// Timeout par requête. Défaut 5 s si zéro.
	Timeout time.Duration
	// Types à interroger. Défaut DefaultTypes si vide.
	Types []string
}

// Record est un enregistrement résolu.
type Record struct {
	RecordType string `json:"record_type"`
	Name       string `json:"name"`
	Value      string `json:"value"`
	TTL        uint32 `json:"ttl"`
}

// Records est le résultat agrégé d'un appel à Resolve.
type Records struct {
	Target  string   `json:"target"`
	Records []Record `json:"records"`
	// FailedTypes liste les types qui ont échoué (timeout, NXDOMAIN
	// pour ce type, etc.). Quand FailedTypes est non vide mais
	// Records aussi, le statut métier est "partial".
	FailedTypes []string `json:"failed_types,omitempty"`
}

// Resolve interroge chacun des types de cfg.Types et agrège les
// résultats. Un type qui échoue (timeout, refus du résolveur,
// NXDOMAIN ciblé) n'arrête pas la résolution des autres types — il
// est juste reporté dans FailedTypes.
func Resolve(ctx context.Context, target string, cfg Config) (Records, error) {
	target = strings.TrimSpace(target)
	if target == "" {
		return Records{}, fmt.Errorf("dnsprobe: empty target")
	}
	cfg = withDefaults(cfg)
	if err := validateTypes(cfg.Types); err != nil {
		return Records{}, err
	}

	resolver := cfg.Resolver
	if resolver == "" {
		resolver = systemResolver()
	}

	out := Records{Target: target}
	client := &dns.Client{
		Net:     "udp",
		Timeout: cfg.Timeout,
	}

	for _, typeName := range cfg.Types {
		records, err := queryOne(ctx, client, resolver, target, typeName)
		if err != nil {
			out.FailedTypes = append(out.FailedTypes, typeName)
			continue
		}
		out.Records = append(out.Records, records...)
	}
	return out, nil
}

func queryOne(ctx context.Context, client *dns.Client, resolver, target, typeName string) ([]Record, error) {
	qtype, ok := AllowedTypes[typeName]
	if !ok {
		return nil, fmt.Errorf("dnsprobe: type %q not allowed", typeName)
	}

	msg := new(dns.Msg)
	msg.SetQuestion(dns.Fqdn(target), qtype)
	msg.RecursionDesired = true

	resp, _, err := client.ExchangeContext(ctx, msg, resolver)
	if err != nil {
		return nil, err
	}
	if resp == nil {
		return nil, fmt.Errorf("dnsprobe: no response")
	}

	out := make([]Record, 0, len(resp.Answer))
	for _, ans := range resp.Answer {
		rec, ok := toRecord(target, ans)
		if !ok {
			continue
		}
		out = append(out, rec)
	}
	return out, nil
}

func toRecord(target string, rr dns.RR) (Record, bool) {
	hdr := rr.Header()
	rec := Record{
		Name: strings.TrimSuffix(hdr.Name, "."),
		TTL:  hdr.Ttl,
	}
	switch v := rr.(type) {
	case *dns.A:
		rec.RecordType = "A"
		rec.Value = v.A.String()
	case *dns.AAAA:
		rec.RecordType = "AAAA"
		rec.Value = v.AAAA.String()
	case *dns.MX:
		rec.RecordType = "MX"
		rec.Value = fmt.Sprintf("%d %s", v.Preference, strings.TrimSuffix(v.Mx, "."))
	case *dns.NS:
		rec.RecordType = "NS"
		rec.Value = strings.TrimSuffix(v.Ns, ".")
	case *dns.TXT:
		rec.RecordType = "TXT"
		rec.Value = strings.Join(v.Txt, "")
	case *dns.CAA:
		rec.RecordType = "CAA"
		rec.Value = fmt.Sprintf("%d %s %q", v.Flag, v.Tag, v.Value)
	case *dns.SOA:
		rec.RecordType = "SOA"
		rec.Value = fmt.Sprintf("%s %s %d %d %d %d %d",
			strings.TrimSuffix(v.Ns, "."),
			strings.TrimSuffix(v.Mbox, "."),
			v.Serial, v.Refresh, v.Retry, v.Expire, v.Minttl,
		)
	case *dns.CNAME:
		rec.RecordType = "CNAME"
		rec.Value = strings.TrimSuffix(v.Target, ".")
	default:
		return Record{}, false
	}
	if rec.Name == "" {
		rec.Name = target
	}
	return rec, true
}

func withDefaults(cfg Config) Config {
	if cfg.Timeout <= 0 {
		cfg.Timeout = 5 * time.Second
	}
	if len(cfg.Types) == 0 {
		cfg.Types = DefaultTypes
	}
	return cfg
}

func validateTypes(types []string) error {
	for _, t := range types {
		if _, ok := AllowedTypes[t]; !ok {
			return fmt.Errorf("dnsprobe: type %q not in AllowedTypes (interdit : zone transfer)", t)
		}
	}
	return nil
}

// systemResolver lit la première entrée nameserver de /etc/resolv.conf.
// On reste explicite : pas de fallback magique sur 8.8.8.8 — si la
// config locale n'a rien, on retourne un fallback localhost-only que
// l'opérateur peut surcharger via Config.Resolver.
func systemResolver() string {
	cfg, err := dns.ClientConfigFromFile("/etc/resolv.conf")
	if err != nil || len(cfg.Servers) == 0 {
		return "127.0.0.1:53"
	}
	port := cfg.Port
	if port == "" {
		port = "53"
	}
	return cfg.Servers[0] + ":" + port
}
