// scanner-http_banner : binaire spécialisé `scan:http_banner`.
package main

import (
	"os"

	"github.com/banux/Reconaut/apps/scanner/internal/runtime"
)

func main() {
	os.Exit(runtime.Run(runtime.Config{
		ScanKind: "http_banner",
		Args:     os.Args[1:],
	}))
}
