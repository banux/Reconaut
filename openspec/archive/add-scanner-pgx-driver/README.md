# Archived: `add-scanner-pgx-driver`

**Superseded by** : [`remote-scanner-agents`](../../changes/remote-scanner-agents/proposal.md).

## Pourquoi archivé

Ce change a été implémenté le 2026-05-12 puis **largement annulé le 2026-05-13** par `remote-scanner-agents`.

Le besoin opérateur fondamental qui a motivé `remote-scanner-agents` :

> « Ce que je n'aime pas c'est que les workers ont besoin d'accès à la base de données, je ne peux pas les faire tourner sur un serveur trop séparé. »

Ce besoin invalide la décision centrale de `add-scanner-pgx-driver` (lier pgx dans les binaires Go pour que les workers accèdent à Postgres). Le pivot retient les workers comme **clients MCP HTTP** de Rails — Rails reste seul à toucher la DB.

## Ce qui reste vivant

- La **migration Rails `20260513000001_create_scan_results.rb`** (table `scan_results`). Utile au design final — c'est Rails qui y écrit désormais via le tool MCP `submit_scan_result`.
- Le script `scripts/check_scanner_deps_licenses.sh` reste en place ; sa liste est juste réduite (pgx + transitives retirés).

## Ce qui a été retiré

- Le pilote pgx (`github.com/jackc/pgx/v5/stdlib`) et le blank import dans `internal/runtime`.
- Le package `results.SQLStore` et `goodjob.SQLStore`.
- Le mode SQL de `runtime.wireStores` (remplacé par `agentLoop` côté HTTP).
- La dépendance Go `github.com/DATA-DOG/go-sqlmock`.

Pour le rationale complet du retour en arrière, voir [`remote-scanner-agents/proposal.md`](../../changes/remote-scanner-agents/proposal.md).
