// Package main is the entrypoint for the scanner-worker binary.
//
// Spec source: openspec/changes/add-tech-stack/specs/architecture/spec.md
// (workers Go autonomes consomment good_jobs via SELECT ... FOR UPDATE
// SKIP LOCKED, pas de broker externe).
//
// Iteration courante : binaire squelette qui imprime sa version et sort.
// La boucle de consommation good_jobs sera ajoutee a l'iteration de
// add-tech-stack section 5.1.
package main

import (
	"fmt"
	"os"

	"github.com/banux/Reconaut/apps/scanner/internal/worker"
)

func main() {
	fmt.Printf("scanner-worker %s\n", worker.Version)
	os.Exit(0)
}
