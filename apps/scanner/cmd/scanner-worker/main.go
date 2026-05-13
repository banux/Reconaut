// SPDX-License-Identifier: AGPL-3.0-only
// Package main : scanner-worker — binaire générique multi-queue.
//
// Depuis remote-scanner-agents (2026-05-13), tous les binaires
// scanner-<kind> sont des clients MCP HTTP : ils n'accèdent plus
// directement à Postgres. La boucle de claim/submit/fail vit dans
// internal/runtime. scanner-worker reste comme entrypoint de
// commodité pour les tests ; un opérateur préfère les binaires
// spécialisés `scanner-<kind>` qui scopent automatiquement leur queue.
//
// Cf. openspec/changes/remote-scanner-agents/specs/scanning/spec.md
//   -> Requirement: Workers Go consomment la file via MCP HTTP
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/banux/Reconaut/apps/scanner/internal/runtime"
)

func main() {
	// Le scan_kind est lu depuis l'env RECONAUT_QUEUE (par compat) ou
	// le flag --kind, défaut "generic". Format attendu : juste le kind,
	// pas "scan:<kind>" — runtime.Run préfixe la queue lui-même.
	kind := envOr("RECONAUT_QUEUE", "generic")
	kind = strings.TrimPrefix(kind, "scan:") // tolérer la forme historique

	// Parse les flags partagés (gérés par runtime.Run aussi, mais on
	// les retire d'os.Args pour passer le reste à runtime).
	fs := flag.NewFlagSet("scanner-worker", flag.ContinueOnError)
	flagKind := fs.String("kind", "", "override scan_kind to consume (default: $RECONAUT_QUEUE)")
	args, err := splitOwnArgs(fs, os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(64)
	}
	if *flagKind != "" {
		kind = *flagKind
	}

	os.Exit(runtime.Run(runtime.Config{
		ScanKind: kind,
		Args:     args,
	}))
}

// splitOwnArgs traite les flags `--kind` et laisse passer le reste
// (--version, --dry-run, --idle-backoff) à runtime.Run.
func splitOwnArgs(fs *flag.FlagSet, in []string) ([]string, error) {
	rest := []string{}
	i := 0
	for i < len(in) {
		a := in[i]
		if a == "--kind" || strings.HasPrefix(a, "--kind=") {
			if a == "--kind" && i+1 < len(in) {
				if err := fs.Parse([]string{a, in[i+1]}); err != nil {
					return nil, err
				}
				i += 2
				continue
			}
			if err := fs.Parse([]string{a}); err != nil {
				return nil, err
			}
		} else {
			rest = append(rest, a)
		}
		i++
	}
	return rest, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
