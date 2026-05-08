// scanner-service_fingerprint : binaire spécialisé `scan:service_fingerprint`.
package main

import (
	"os"

	"github.com/banux/Reconaut/apps/scanner/internal/runtime"
)

func main() {
	os.Exit(runtime.Run(runtime.Config{
		ScanKind: "service_fingerprint",
		Args:     os.Args[1:],
	}))
}
