# Spec delta : scanning

## ADDED Requirements

### Requirement: Asset Discovery Pipeline
Le système DOIT scanner les plages IPv4 publiques et un ensemble configurable et échantillonné de préfixes IPv6 pour découvrir les hôtes répondants, en capturant l'IP, l'ASN, la géolocalisation (ISO 3166-1 alpha-2), le reverse-DNS (s'il existe) et les timestamps `discovered_at` / `last_seen`.

#### Scenario: Nouvel hôte découvert
- **WHEN** le planificateur exécute une fenêtre de scan couvrant un `/24` contenant au moins un hôte répondant
- **THEN** le système enregistre exactement une ligne `host` par IP répondante avec ASN, pays, reverse-DNS (ou `null`) et `discovered_at`
- **AND** les hôtes déjà connus dans cette plage voient leur champ `last_seen` mis à jour dans la même transaction de base de données

#### Scenario: Hôte non répondant reste absent
- **WHEN** un `/24` n'a aucun hôte répondant durant la fenêtre de scan
- **THEN** aucune ligne n'est écrite et l'exécution est marquée `completed_empty` avec le nombre de sondes et la durée enregistrés

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
Le scanner DOIT imposer des rate limits par cible et par AS, DOIT ignorer les cibles publiant un opt-out DNS, et DOIT respecter `robots.txt` pour toute sonde HTTP au-delà de la page d'index.

#### Scenario: Limite par AS tenue
- **GIVEN** une limite par AS configurée à 50 requêtes/seconde
- **WHEN** le planificateur dispatche des sondes vers les hôtes de cet AS
- **THEN** le débit sortant réel mesuré au NIC d'egress sur toute fenêtre de 10 secondes est ≤ 55 rps (tolérance 5 %) et ≥ 0 rps

#### Scenario: Cible demande l'opt-out via DNS TXT
- **GIVEN** le domaine apex d'une cible publie `_reconaut-optout TXT "1"`
- **WHEN** le scanner planifie une sonde contre ce domaine ou contre un hôte de l'ensemble A/AAAA résolu de ce domaine
- **THEN** la sonde est ignorée, la décision est journalisée avec la raison `optout-dns`, et le domaine apex est ajouté au cache d'opt-out pour 30 jours

#### Scenario: robots.txt interdit le crawl profond
- **GIVEN** un hôte dont le `robots.txt` interdit `/admin`
- **WHEN** le sondeur HTTP envisage de récupérer `/admin`
- **THEN** la requête n'est pas émise et la décision est journalisée avec la raison `robots-disallow`

### Requirement: Indexing and Retention
Les données de scan capturées DEVRONT être stockées dans un store partitionné par temps avec une rétention par défaut de 90 jours en tier chaud et 24 mois en tier froid. Chaque tenant DEVRA pouvoir surcharger la rétention dans les limites définies par la plateforme.

#### Scenario: Tenant demande 12 mois de rétention chaude
- **WHEN** un admin tenant définit `retention.hot_days = 365` via l'API
- **THEN** les résultats de scan ultérieurs pour ce tenant sont conservés en tier chaud pendant 365 jours
- **AND** le changement est journalisé dans le journal d'audit en moins de 1 seconde avec acteur, ancienne valeur et nouvelle valeur

#### Scenario: Rétention par défaut appliquée
- **GIVEN** un tenant qui n'a jamais surchargé la rétention
- **WHEN** l'âge d'une ligne de scan dépasse 90 jours
- **THEN** la ligne est migrée du tier chaud vers le tier froid lors du prochain job nocturne de rétention
