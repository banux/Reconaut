# Spec delta : architecture

## MODIFIED Requirements

### Requirement: Specialized Scan Workers per scan_kind
La plateforme DOIT livrer **un binaire Go par `scan_kind`** sous `apps/scanner/cmd/scanner-<kind>/`. Chaque binaire consomme la queue GoodJob `scan:<kind>` (constante par binaire) et n'importe que les sondeurs de son protocole. La spécialisation réduit la surface d'attaque par binaire et permet à l'opérateur de scaler chaque type indépendamment.

Les `scan_kind` couverts en v1 (extension par rapport à `replace-web-with-tui`) :

| `scan_kind`           | Binaire                                          | Queue GoodJob              | Cible(s) acceptée(s)              |
|-----------------------|--------------------------------------------------|----------------------------|-----------------------------------|
| `tcp_probe`           | `apps/scanner/cmd/scanner-tcp_probe/`            | `scan:tcp_probe`           | `ip`, `cidr`, `host`              |
| `tls_capture`         | `apps/scanner/cmd/scanner-tls_capture/`          | `scan:tls_capture`         | `ip`, `host`, `domain`            |
| `http_banner`         | `apps/scanner/cmd/scanner-http_banner/`          | `scan:http_banner`         | `ip`, `host`, `domain`            |
| `subdomain_enum`      | `apps/scanner/cmd/scanner-subdomain_enum/`       | `scan:subdomain_enum`      | `domain`                          |
| `service_fingerprint` | `apps/scanner/cmd/scanner-service_fingerprint/`  | `scan:service_fingerprint` | `ip`, `host`                      |
| **`dns_records`**     | **`apps/scanner/cmd/scanner-dns_records/`**      | **`scan:dns_records`**     | **`domain`, `host`**              |

Le linter `scripts/check_scanner_specialization.sh` DOIT vérifier que les 6 binaires attendus existent et qu'aucun import croisé entre binaires n'est introduit.

#### Scenario: Le binaire scanner-dns_records existe et consomme sa queue dédiée
- **GIVEN** une release du repo
- **WHEN** un opérateur invoque `apps/scanner/cmd/scanner-dns_records/scanner-dns_records --version`
- **THEN** le binaire imprime sa version et exit 0
- **AND** au runtime, le binaire ne consomme QUE la queue `scan:dns_records` (les jobs des autres queues, par ex. `scan:tcp_probe`, restent dans la table `good_jobs`)

#### Scenario: Linter rejette l'absence du binaire dns_records
- **WHEN** un contributeur supprime `apps/scanner/cmd/scanner-dns_records/main.go`
- **THEN** `scripts/check_scanner_specialization.sh` échoue avec un message nommant le binaire manquant
- **AND** la PR ne peut pas être fusionnée tant que le binaire n'est pas restauré

#### Scenario: Cible non-domaine rejetée par le scanner DNS
- **GIVEN** un payload `ScanJobV1` avec `scan_kind="dns_records"` et `target.kind="ip"`
- **WHEN** le worker `scanner-dns_records` claim ce job
- **THEN** le job est marqué en échec avec `error="invalid_target: dns_records requires target_kind in {domain, host}, got ip"`
- **AND** aucune requête DNS n'est émise vers le réseau
- **AND** une ligne d'audit côté Rails enregistre l'échec avec `outcome=invalid_target`
