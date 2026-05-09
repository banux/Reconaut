// SPDX-License-Identifier: AGPL-3.0-only
// scanner-tcp_probe : binaire spécialisé qui consomme la file
// `scan:tcp_probe` et applique les sondeurs TCP. Cf.
// openspec/changes/replace-web-with-tui/specs/architecture/spec.md
// (Requirement: Specialized Scan Workers per scan_kind).
package main

import (
	"os"

	"github.com/banux/Reconaut/apps/scanner/internal/runtime"
)

func main() {
	os.Exit(runtime.Run(runtime.Config{
		ScanKind: "tcp_probe",
		Args:     os.Args[1:],
	}))
}
