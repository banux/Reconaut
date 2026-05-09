// SPDX-License-Identifier: AGPL-3.0-only
// scanner-tls_capture : binaire spécialisé `scan:tls_capture`.
package main

import (
	"os"

	"github.com/banux/Reconaut/apps/scanner/internal/runtime"
)

func main() {
	os.Exit(runtime.Run(runtime.Config{
		ScanKind: "tls_capture",
		Args:     os.Args[1:],
	}))
}
