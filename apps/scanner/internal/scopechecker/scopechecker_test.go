// SPDX-License-Identifier: AGPL-3.0-only
package scopechecker

import (
	"context"
	"testing"
)

// Cf. openspec/changes/init-reconaut-platform/tasks.md §2.2 :
// "Test d'intégration injecte un job pour 203.0.113.5 sans entrée de
// scope ; assure (a) aucun paquet sortant, (b) statut out-of-scope
// persisté, (c) ligne d'audit. Un job pour 192.0.2.10 avec une entrée
// de scope 192.0.2.0/24 active passe."

func TestInMemoryChecker_CIDR(t *testing.T) {
	c := NewInMemoryChecker([]Entry{
		{Kind: "cidr", Value: "192.0.2.0/24"},
	})

	cases := []struct {
		name       string
		kind       string
		value      string
		wantInScope bool
	}{
		{"ip in CIDR", "ip", "192.0.2.10", true},
		{"ip outside CIDR", "ip", "203.0.113.5", false},
		{"sub-CIDR", "cidr", "192.0.2.128/25", true},
		{"sub-CIDR with broader mask", "cidr", "192.0.0.0/16", false},
		{"host (string equality)", "host", "192.0.2.10", true}, // host as IP literal
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ok, err := c.IsInScope(context.Background(), tc.kind, tc.value)
			if err != nil {
				t.Fatalf("error: %v", err)
			}
			if ok != tc.wantInScope {
				t.Errorf("kind=%s value=%s : got %v want %v", tc.kind, tc.value, ok, tc.wantInScope)
			}
		})
	}
}

func TestInMemoryChecker_Domain(t *testing.T) {
	c := NewInMemoryChecker([]Entry{
		{Kind: "domain", Value: "example.fr"},
	})

	cases := []struct {
		name       string
		kind       string
		value      string
		wantInScope bool
	}{
		{"exact domain", "domain", "example.fr", true},
		{"case-insensitive", "domain", "Example.FR", true},
		{"subdomain not covered (v1)", "domain", "sub.example.fr", false},
		{"host with same value not covered by domain entry", "host", "example.fr", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ok, err := c.IsInScope(context.Background(), tc.kind, tc.value)
			if err != nil {
				t.Fatalf("error: %v", err)
			}
			if ok != tc.wantInScope {
				t.Errorf("kind=%s value=%s : got %v want %v", tc.kind, tc.value, ok, tc.wantInScope)
			}
		})
	}
}

func TestInMemoryChecker_Host(t *testing.T) {
	c := NewInMemoryChecker([]Entry{
		{Kind: "host", Value: "mail.example.fr"},
	})
	ok, _ := c.IsInScope(context.Background(), "host", "mail.example.fr")
	if !ok {
		t.Error("expected exact host match")
	}
	ok, _ = c.IsInScope(context.Background(), "host", "Mail.Example.FR")
	if !ok {
		t.Error("expected case-insensitive host match")
	}
	ok, _ = c.IsInScope(context.Background(), "host", "other.example.fr")
	if ok {
		t.Error("expected mismatch on different host")
	}
}

func TestInMemoryChecker_NoEntries(t *testing.T) {
	c := NewInMemoryChecker(nil)
	ok, err := c.IsInScope(context.Background(), "ip", "192.0.2.1")
	if err != nil {
		t.Fatalf("error: %v", err)
	}
	if ok {
		t.Error("expected out of scope when no entries declared")
	}
}

func TestInMemoryChecker_MultipleEntriesAnyMatches(t *testing.T) {
	c := NewInMemoryChecker([]Entry{
		{Kind: "cidr", Value: "192.0.2.0/24"},
		{Kind: "domain", Value: "example.fr"},
		{Kind: "host", Value: "mail.example.fr"},
	})

	ok, _ := c.IsInScope(context.Background(), "ip", "192.0.2.10")
	if !ok {
		t.Error("expected match via cidr")
	}
	ok, _ = c.IsInScope(context.Background(), "domain", "example.fr")
	if !ok {
		t.Error("expected match via domain")
	}
	ok, _ = c.IsInScope(context.Background(), "host", "mail.example.fr")
	if !ok {
		t.Error("expected match via host")
	}
	ok, _ = c.IsInScope(context.Background(), "ip", "203.0.113.5")
	if ok {
		t.Error("expected miss for unrelated IP")
	}
}
