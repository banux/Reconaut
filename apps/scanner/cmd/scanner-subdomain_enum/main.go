// SPDX-License-Identifier: AGPL-3.0-only
// scanner-subdomain_enum : binaire spécialisé `scan:subdomain_enum`.
package main

import (
	"os"

	"github.com/banux/Reconaut/apps/scanner/internal/runtime"
)

func main() {
	os.Exit(runtime.Run(runtime.Config{
		ScanKind: "subdomain_enum",
		Args:     os.Args[1:],
	}))
}
