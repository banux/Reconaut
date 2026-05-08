# Spec delta : integrations

## ADDED Requirements

### Requirement: Inbound Integration via ScanResultV1
La plateforme DOIT accepter l'ingestion de résultats de scan provenant de **sources externes** (scanners tiers, exports de bases publiques, scripts maison) en réutilisant le schéma de message déjà figé pour les workers internes : `ScanResultV1` (cf. `packages/job-schema/scan_result_v1.json`). Aucun format alternatif ne DOIT être introduit en v1 — toute donnée entrante DOIT être normalisée par l'appelant en `ScanResultV1` avant ingestion.

L'ingestion est exposée comme **outil MCP** (`ingest_scan_result`, scope `write:scans`), pas comme route REST. La cible (`target`) du payload ingéré DOIT être couverte par une entrée de scope active, exactement comme un scan interne — aucun raccourci pour pousser des données hors scope.

#### Scenario: Outil externe pousse un résultat de scan via MCP
- **GIVEN** un opérateur a configuré un wrapper externe (par ex. un script qui exécute nmap puis convertit en `ScanResultV1`)
- **AND** une clé API avec scope `write:scans` est utilisée par ce wrapper
- **AND** la cible du résultat est couverte par une entrée de scope active
- **WHEN** le wrapper invoque `ingest_scan_result(payload)` via MCP HTTP+SSE
- **THEN** la plateforme valide le payload contre `ScanResultV1`, persiste les hôtes/services/certificats correspondants comme s'ils venaient d'un worker interne
- **AND** une ligne d'audit est écrite avec `actor_key_id`, `tool=ingest_scan_result`, `target`, `source=<source field si fourni, sinon "external">`

#### Scenario: Ingestion d'une cible hors scope rejetée
- **GIVEN** une cible hors scope déclaré
- **WHEN** un client invoque `ingest_scan_result` avec un payload visant cette cible
- **THEN** la plateforme rejette avec `out-of-scope` (même code d'erreur que `request_scan`)
- **AND** aucune donnée n'est persistée
- **AND** une ligne d'audit avec `outcome=out-of-scope` est écrite

#### Scenario: Payload mal formé rejeté
- **GIVEN** un payload qui ne matche pas le schéma `ScanResultV1` (champ requis manquant, type incorrect, etc.)
- **WHEN** un client invoque `ingest_scan_result(payload)`
- **THEN** la plateforme rejette avec `invalid_payload` et la liste des erreurs de validation JSON Schema
- **AND** rien n'est persisté

#### Scenario: Idempotence d'ingestion par idempotency_key
- **GIVEN** un payload avec `idempotency_key="K"` déjà ingéré
- **WHEN** le même payload (ou un payload différent avec la même `idempotency_key`) est réinjecté
- **THEN** la seconde ingestion est détectée et acquittée sans seconde écriture des lignes métier
- **AND** une ligne d'audit `outcome=duplicate` est écrite (pour tracer la tentative)

### Requirement: Source Tagging on Ingested Data
Tout enregistrement (hôte, service, certificat, etc.) issu d'une ingestion externe DOIT porter un attribut `source` qui distingue les données auto-collectées (workers Go internes) des données ingérées (`source=external` ou nom du connecteur si fourni : `"nmap"`, `"nuclei"`, etc.). Cet attribut DOIT être consultable via les outils MCP de lecture (`get_host`, `search_hosts` exposent le champ `source` dans les résultats).

#### Scenario: Source tracée sur un hôte ingéré
- **GIVEN** un hôte ingéré via `ingest_scan_result` avec `payload.source="nmap"`
- **WHEN** un client invoque `get_host(host_id)`
- **THEN** la réponse contient `source: "nmap"` (ou liste de sources si plusieurs origines)
- **AND** un test confirme que les hôtes auto-collectés portent `source: "internal"`

#### Scenario: Plusieurs sources convergent sur le même host_id
- **GIVEN** un même host découvert par un scan interne ET ingéré depuis nmap
- **WHEN** un client lit cet hôte
- **THEN** le champ `sources` est une liste contenant `["internal", "nmap"]` (l'ordre n'est pas garanti)
- **AND** la latest scan timestamp est la plus récente des deux
