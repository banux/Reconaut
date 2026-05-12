# Spec delta : platform

## ADDED Requirements

### Requirement: Migration scan_results table
La migration Rails `db/migrate/<timestamp>_create_scan_results.rb` DOIT créer une table `scan_results` qui sert de cible aux écritures des workers Go via `results.SQLStore`. La table DOIT :

- avoir `idempotency_key TEXT PRIMARY KEY` (déduplication forte côté DB) ;
- avoir des colonnes `scan_kind TEXT NOT NULL`, `target_kind TEXT NOT NULL`, `target_value TEXT NOT NULL`, `status TEXT NOT NULL`, `observed_at TIMESTAMPTZ NOT NULL` ;
- avoir les timestamps `created_at` et `updated_at` (default `NOW()`) pour observabilité ;
- avoir des index sur `scan_kind`, `(target_kind, target_value)`, et `observed_at` (pour les requêtes ad-hoc de tri/filtre côté Rails ou via une future MCP tool) ;
- **NE PAS** être convertie en hypertable TimescaleDB en v1 (différé à `add-scan-results-hypertable`).

La migration DOIT être idempotente (rejouable sans erreur) et n'inclure AUCUNE clé étrangère vers `hosts`, `services` ou `scans` — le worker Go écrit sans connaître les modèles ActiveRecord. Le lien sémantique (par exemple `target_value=<ip>` → `hosts.ip`) est laissé à la couche d'analyse Rails ultérieure.

#### Scenario: Migration crée la table avec le schéma attendu
- **GIVEN** une base `reconaut_test` propre
- **WHEN** `RAILS_ENV=test bundle exec rails db:migrate` est exécuté
- **THEN** la table `scan_results` existe avec les colonnes : `idempotency_key`, `scan_kind`, `target_kind`, `target_value`, `status`, `observed_at`, `created_at`, `updated_at`
- **AND** `idempotency_key` est PRIMARY KEY (visible via `\d scan_results`)
- **AND** un test rspec contre `ActiveRecord::Base.connection.columns(:scan_results)` valide la liste

#### Scenario: Index présents et utilisables
- **GIVEN** la table migrée
- **WHEN** un test exécute `SELECT 1 FROM pg_indexes WHERE tablename = 'scan_results'`
- **THEN** il retourne ≥ 3 lignes (idempotency_key PK + scan_kind + (target_kind, target_value) + observed_at)

#### Scenario: ON CONFLICT DO NOTHING fonctionne côté DB
- **GIVEN** la table migrée + une ligne avec `idempotency_key='k1'`
- **WHEN** un test exécute `INSERT INTO scan_results (...) VALUES ('k1', ...) ON CONFLICT (idempotency_key) DO NOTHING`
- **THEN** la requête s'exécute sans erreur
- **AND** `SELECT COUNT(*) FROM scan_results WHERE idempotency_key='k1'` retourne 1 (pas 2)

## ADDED Requirements

### Requirement: Connection management côté worker Go
Le wireup DB côté `internal/runtime` DOIT configurer :

- `db.SetMaxOpenConns(8)` — borne le pool par worker pour ne pas saturer Postgres.
- `db.SetMaxIdleConns(2)` — garde quelques conns chaudes.
- `db.SetConnMaxLifetime(5 * time.Minute)` — recycle les conns régulièrement (utile derrière un pgBouncer ou un firewall qui ferme les flux inactifs).
- Un `PingContext` au démarrage avec un timeout strict ≤ 2 s pour fail-fast.
- Un `defer db.Close()` propagé à `runtime.Run` pour shutdown propre (libère les conns à la sortie du binaire).

#### Scenario: shutdown propre ferme la DB
- **GIVEN** un binaire scanner-* lancé en mode SQL
- **WHEN** le binaire reçoit `SIGTERM`
- **THEN** le binaire termine ses jobs en cours, log un `shutting down`, et appelle `db.Close()`
- **AND** un test unitaire (en remplaçant `db` par un mock qui compte les Close calls) vérifie qu'exactement UN `Close` est appelé sur le chemin de shutdown
