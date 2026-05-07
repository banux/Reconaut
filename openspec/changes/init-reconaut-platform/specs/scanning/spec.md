# Spec delta : scanning

## ADDED Requirements

### Requirement: Asset Discovery Pipeline
Le système DOIT scanner uniquement les actifs couverts par une entrée de scope **explicitement déclarée par l'opérateur** (CIDR, domaine ou hôte). Aucun balayage du grand internet n'est livré : sans entrée de scope active, le scanner n'émet aucune sonde. Pour chaque hôte découvert dans le scope, le système capture l'IP, l'ASN, la géolocalisation (ISO 3166-1 alpha-2 si dérivable des bases ouvertes embarquées, sinon `null`), le reverse-DNS (s'il existe) et les timestamps `discovered_at` / `last_seen`.

#### Scenario: Nouvel hôte découvert dans le scope
- **GIVEN** une entrée de scope active de `kind=cidr` couvrant `192.0.2.0/24`
- **WHEN** le planificateur exécute une fenêtre de scan sur cette plage et au moins un hôte répond
- **THEN** le système enregistre exactement une ligne `host` par IP répondante avec ASN, pays (si disponible), reverse-DNS (ou `null`) et `discovered_at`
- **AND** les hôtes déjà connus dans cette plage voient leur champ `last_seen` mis à jour dans la même transaction de base

#### Scenario: Cible hors scope refusée en dur
- **GIVEN** aucune entrée de scope active ne couvre `203.0.113.10`
- **WHEN** un job de scan ciblant `203.0.113.10` est consommé par un worker
- **THEN** le worker rejette le job avec le statut `out-of-scope`, n'émet **aucun paquet** vers la cible, et écrit une ligne d'audit avec `actor`, `target=203.0.113.10`, `reason=out-of-scope`
- **AND** un test réseau confirme qu'aucun socket sortant vers `203.0.113.10` n'a été ouvert

### Requirement: Scope Declaration and Enforcement
L'opérateur DOIT déclarer explicitement le scope autorisé sous forme d'entrées typées (`cidr`, `domain`, `host`). Toute mutation du scope (ajout, révocation) DOIT être journalisée dans le journal d'audit avec l'acteur, la valeur et la raison. Le scanner DOIT vérifier l'appartenance d'une cible au scope **au moment de l'exécution** du job (résolution DNS pour les entrées `domain` faite à ce moment-là), pas seulement à la planification.

#### Scenario: Ajout d'une entrée de scope
- **GIVEN** un opérateur authentifié avec rôle `admin`
- **WHEN** il appelle `POST /scopes` avec `{ "kind": "cidr", "value": "192.0.2.0/24", "description": "Périmètre de prod" }`
- **THEN** une ligne est créée avec `created_by`, `created_at` et `revoked_at = NULL`
- **AND** une ligne d'audit `action=scope.created` est écrite en moins de 1 s
- **AND** un job de scan ultérieur ciblant `192.0.2.10` n'est plus rejeté `out-of-scope`

#### Scenario: Révocation d'une entrée de scope
- **GIVEN** une entrée de scope active couvrant `192.0.2.0/24`
- **WHEN** l'opérateur appelle `DELETE /scopes/{id}`
- **THEN** `revoked_at` est posé sur la ligne (pas de suppression en dur)
- **AND** une ligne d'audit `action=scope.revoked` est écrite
- **AND** un job de scan ultérieur ciblant `192.0.2.10` est de nouveau rejeté `out-of-scope`

#### Scenario: Vérification au runtime (résolution DNS d'une entrée domain)
- **GIVEN** une entrée de scope active `kind=domain`, `value=example.test`
- **WHEN** un job de scan résout `example.test` à `192.0.2.10` au moment de l'exécution
- **THEN** la sonde sur `192.0.2.10` est autorisée
- **AND** si une révocation de l'entrée intervient entre la planification et l'exécution, la sonde est rejetée `out-of-scope` même si elle avait été planifiée précédemment

### Requirement: Port and Service Fingerprinting
Pour chaque hôte découvert, le système DEVRA sonder une liste configurable de ports TCP et UDP et capturer les bannières, les certificats TLS feuille et les fingerprints spécifiques aux protocoles HTTP(S), SSH, RDP, MQTT, CoAP et Modbus.

#### Scenario: Service HTTPS détecté sur TCP/443
- **WHEN** TCP/443 est ouvert sur un hôte
- **THEN** le système stocke le certificat TLS feuille (octets DER, hash SHA-256, SAN, `not_after`), les entrées ALPN (HTTP/1.1 et/ou HTTP/2), les en-têtes de réponse, le token `Server`, et un extrait HTML plafonné à 32 KiB
- **AND** enregistre le `duration_ms`, `bytes_received` et `outcome` (`success` | `timeout` | `reset` | `tls_error`) de la sonde

#### Scenario: Bannière SSH capturée sur TCP/22
- **WHEN** TCP/22 est ouvert sur un hôte
- **THEN** la bannière de protocole SSH (par ex. `SSH-2.0-OpenSSH_8.9p1`) et le fingerprint de la host-key (SHA-256) sont enregistrés ; aucune tentative d'authentification n'est effectuée

### Requirement: Scan Rate Limiting and Abuse Controls
Le scanner DOIT imposer des rate limits par cible et par AS pour ne pas saturer le périmètre scanné, et DOIT respecter `robots.txt` pour toute sonde HTTP au-delà de la page d'index.

#### Scenario: Limite par AS tenue
- **GIVEN** une limite par AS configurée à 50 requêtes/seconde
- **WHEN** le planificateur dispatche des sondes vers les hôtes de cet AS (tous dans le scope)
- **THEN** le débit sortant réel mesuré au NIC d'egress sur toute fenêtre de 10 secondes est ≤ 55 rps (tolérance 5 %) et ≥ 0 rps

#### Scenario: robots.txt interdit le crawl profond
- **GIVEN** un hôte du scope dont le `robots.txt` interdit `/admin`
- **WHEN** le sondeur HTTP envisage de récupérer `/admin`
- **THEN** la requête n'est pas émise et la décision est journalisée avec la raison `robots-disallow`

### Requirement: Indexing and Retention
Les données de scan capturées DEVRONT être stockées dans un store partitionné par temps (TimescaleDB) avec une rétention par défaut de 90 jours en tier chaud et 24 mois en tier froid. Le tier froid DOIT être implémenté soit (a) dans une table Postgres archive compressée (TimescaleDB compression), soit (b) sous forme de fichiers sur le filesystem local (volume monté), au choix de l'opérateur via configuration. Aucune dépendance à un stockage objet S3-compatible n'est introduite. L'opérateur DEVRA pouvoir surcharger la rétention dans les limites définies par la plateforme.

#### Scenario: Opérateur demande 12 mois de rétention chaude
- **WHEN** un opérateur définit `retention.hot_days = 365` via l'API
- **THEN** les résultats de scan ultérieurs sont conservés en tier chaud pendant 365 jours
- **AND** le changement est journalisé dans le journal d'audit en moins de 1 seconde avec acteur, ancienne valeur et nouvelle valeur

#### Scenario: Rétention par défaut appliquée — tier froid Postgres compressé
- **GIVEN** une instance configurée `cold_tier.backend=postgres_compressed` (défaut)
- **WHEN** l'âge d'une ligne de scan dépasse 90 jours
- **THEN** la ligne est migrée du tier chaud (chunk Timescale non-compressé) vers le tier froid (chunk Timescale compressé) lors du prochain job nocturne de rétention

#### Scenario: Rétention par défaut appliquée — tier froid filesystem
- **GIVEN** une instance configurée `cold_tier.backend=filesystem` avec `cold_tier.path=/var/lib/reconaut/cold`
- **WHEN** l'âge d'une ligne de scan dépasse 90 jours
- **THEN** les lignes correspondantes sont exportées au format compressé (par ex. JSONL.gz) dans le chemin configuré et supprimées du tier chaud lors du prochain job nocturne
