// SPDX-License-Identifier: AGPL-3.0-only
// Package scopechecker implémente la garde de scope **côté worker Go**.
//
// Depuis remote-scanner-agents (2026-05-13), le scope check primaire est
// effectué côté Rails au moment du `claim_scan_job` (les workers n'ont
// plus accès à Postgres). Ce package conserve un Checker injectable
// pour les workers qui veulent appliquer une garde locale supplémentaire
// (par ex. via une copie du scope distribuée hors bande).
//
// L'implémentation SQLChecker a été retirée — les workers ne lisent
// plus `scan_scope_entries` directement.
//
// Cf. openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
//   -> Requirement: MCP Tool `claim_scan_job` (scope check au claim)
package scopechecker

import (
	"context"
	"net"
	"strings"
)

// Entry est une entrée de scope active (kind ∈ {cidr, domain, host}).
type Entry struct {
	Kind  string
	Value string
}

// Checker est l'interface implémentée par les variantes (SQL,
// in-memory). Retourne (true, nil) si la cible est couverte par au
// moins une entrée active.
type Checker interface {
	IsInScope(ctx context.Context, targetKind, targetValue string) (bool, error)
}

// covers applique la même logique que `ScanScopeEntry#covers?` côté
// Rails : cidr → IPAddr#include?, domain → strict equal, host → strict
// equal. La résolution DNS éventuelle d'un `domain` vers IPs n'est PAS
// faite ici : on compare au format brut. Un opérateur qui veut couvrir
// les IPs derrière un domaine doit ajouter une entrée `cidr` dédiée.
func (e Entry) covers(targetKind, targetValue string) bool {
	switch e.Kind {
	case "cidr":
		// Match si target est une IP dans le CIDR, ou si target est lui-même
		// un CIDR sous-réseau du scope.
		_, network, err := net.ParseCIDR(e.Value)
		if err != nil {
			return false
		}
		switch targetKind {
		case "ip", "host":
			ip := net.ParseIP(targetValue)
			if ip == nil {
				return false
			}
			return network.Contains(ip)
		case "cidr":
			_, sub, err := net.ParseCIDR(targetValue)
			if err != nil {
				return false
			}
			ones, _ := network.Mask.Size()
			subOnes, _ := sub.Mask.Size()
			return subOnes >= ones && network.Contains(sub.IP)
		}
		return false
	case "domain":
		return targetKind == "domain" && strings.EqualFold(e.Value, targetValue)
	case "host":
		return targetKind == "host" && strings.EqualFold(e.Value, targetValue)
	}
	return false
}

// InMemoryChecker est utilisé par les tests et par les workers qui
// distribuent leur scope hors bande (par ex. via un fichier de config
// versionné). Pas de couplage DB.
type InMemoryChecker struct {
	Entries []Entry
}

// NewInMemoryChecker construit un Checker en mémoire.
func NewInMemoryChecker(entries []Entry) *InMemoryChecker {
	return &InMemoryChecker{Entries: entries}
}

// IsInScope applique covers() à chaque entrée injectée.
func (c *InMemoryChecker) IsInScope(_ context.Context, targetKind, targetValue string) (bool, error) {
	for _, e := range c.Entries {
		if e.covers(targetKind, targetValue) {
			return true, nil
		}
	}
	return false, nil
}
