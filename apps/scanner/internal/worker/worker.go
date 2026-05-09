// SPDX-License-Identifier: AGPL-3.0-only
// Package worker contains the scanner worker primitives.
//
// Iteration courante : seulement la constante Version exposee. La boucle
// de consommation good_jobs et les sondeurs viendront aux iterations
// suivantes (cf. add-tech-stack section 5).
package worker

// Version is the scanner-worker semantic version.
const Version = "0.0.0-bootstrap"
