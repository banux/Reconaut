// SPDX-License-Identifier: AGPL-3.0-only
// Package scopechecker implémente la garde de scope **côté worker Go**
// (défense-en-profondeur).
//
// Source de vérité :
//
//	openspec/changes/init-reconaut-platform/tasks.md §2.2
//	  "Avant chaque sonde, le worker vérifie que la cible appartient
//	   à au moins une entrée de scope active. Cible hors scope → job
//	   rejeté avec raison `out-of-scope`, ligne d'audit, pas de paquet
//	   réseau émis."
//
// Le contrat scope-driven Reconaut est appliqué côté Rails par
// `Reconaut::ScanEnqueuer.ensure_in_scope!` AVANT enqueue. Ce package
// re-vérifie côté Go : si un job arrive en file (par exemple parce
// qu'un opérateur a inséré directement dans `good_jobs` ou parce
// qu'une entrée de scope a été révoquée entre l'enqueue et le claim),
// le sondeur refuse de l'exécuter.
//
// Le package expose un Checker injectable :
//
//   - `Checker` : interface (méthode `IsInScope(ctx, kind, value) (bool, error)`).
//   - `SQLChecker` : implémentation Postgres (lit `scan_scope_entries`).
//   - `InMemoryChecker` : pour tests, accepte une liste d'entrées en mémoire.
package scopechecker

import (
	"context"
	"database/sql"
	"fmt"
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

// SQLChecker implémente Checker en lisant `scan_scope_entries` à
// chaque appel (pas de cache : la rotation est rare et le coût d'une
// requête indexée est négligeable comparé au coût d'un faux positif).
type SQLChecker struct {
	db *sql.DB
}

// NewSQLChecker construit un Checker backé par une connexion
// Postgres. Le driver doit être enregistré par l'appelant (typiquement
// `_ "github.com/jackc/pgx/v5/stdlib"`).
func NewSQLChecker(db *sql.DB) *SQLChecker {
	return &SQLChecker{db: db}
}

// IsInScope vérifie qu'au moins une entrée de scope **active**
// (`revoked_at IS NULL`) couvre la cible. Lecture en O(N) sur les
// entrées actives — N est faible par construction (un opérateur
// déclare typiquement < 100 entrées).
func (c *SQLChecker) IsInScope(ctx context.Context, targetKind, targetValue string) (bool, error) {
	rows, err := c.db.QueryContext(ctx,
		`SELECT kind, value FROM scan_scope_entries WHERE revoked_at IS NULL`)
	if err != nil {
		return false, fmt.Errorf("scopechecker: query: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var e Entry
		if err := rows.Scan(&e.Kind, &e.Value); err != nil {
			return false, fmt.Errorf("scopechecker: scan: %w", err)
		}
		if e.covers(targetKind, targetValue) {
			return true, nil
		}
	}
	if err := rows.Err(); err != nil {
		return false, fmt.Errorf("scopechecker: rows: %w", err)
	}
	return false, nil
}

// InMemoryChecker est utilisé par les tests : on injecte directement
// la liste d'entrées actives.
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
