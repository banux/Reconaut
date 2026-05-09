// SPDX-License-Identifier: AGPL-3.0-only
// scanner-worker — DB connection helper.
//
// Le branchement réel d'un driver Postgres (pgx via stdlib, lib/pq) est
// délibérément retardé jusqu'à ce que init-reconaut-platform §2.1
// livre les modèles AR Reconaut côté Rails et la table `results`
// associée. En attendant, le binaire fonctionne en mode `--dry-run`
// (stores en mémoire) — utile pour les tests d'intégration de la
// boucle goodjob et le smoke test du binaire.
//
// Quand le driver sera ajouté, il suffira de :
//   1. ajouter `import _ "github.com/jackc/pgx/v5/stdlib"` ici,
//   2. retirer ce fichier au profit d'un appel `sql.Open("pgx", dbURL)`
//      qui parle directement au cluster.
//
// Cette indirection garde apps/scanner/go.mod vide de dépendances
// externes en v1.

package main

import (
	"database/sql"
	"errors"
)

// errDriverNotLinked is returned by openDB when the binary is built
// without a Postgres driver. The expected call site catches this and
// suggests the operator pass --dry-run.
var errDriverNotLinked = errors.New(
	"scanner-worker: aucun driver Postgres lié dans ce binaire ; " +
		"relancez avec --dry-run pour utiliser les stores en mémoire, " +
		"ou compilez avec un driver via _ \"github.com/jackc/pgx/v5/stdlib\".",
)

func openDB(_ string) (*sql.DB, error) {
	return nil, errDriverNotLinked
}
