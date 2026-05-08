# Spec delta : scanning

## ADDED Requirements

### Requirement: DNS Records Resolution Scanner
La plateforme DOIT exposer un scanner spécialisé qui, pour un domaine ou un host **dans le scope déclaré**, résout les enregistrements DNS publiés et les ingère comme `findings` dans la base de connaissance via `ScanResultV1`. Cette capacité est complémentaire de `subdomain_enum` (qui découvre des sous-domaines) et n'effectue **aucun zone transfer (AXFR)**.

Les types d'enregistrement résolus en v1 DOIVENT inclure :

- `A` (IPv4)
- `AAAA` (IPv6)
- `MX` (mail exchange) avec sa préférence
- `NS` (nameserver)
- `TXT` (texte libre, SPF/DKIM/DMARC, vérifications de service)
- `CAA` (Certificate Authority Authorization)
- `SOA` (Start of Authority — métadonnées de zone)
- `CNAME` (canonical name) si présent

Chaque enregistrement résolu DOIT apparaître dans `ScanResultV1.findings` comme un objet portant au minimum :

```
{
  "type": "dns_record",
  "record_type": "MX" | "TXT" | "A" | ...,
  "name":        "<fqdn interrogé>",
  "value":       "<contenu de l'enregistrement>",
  "ttl":         <integer secondes>
}
```

Le scanner DOIT respecter les contraintes opérationnelles :

- **Pas de zone transfer (AXFR)**. Le scanner émet une requête par type d'enregistrement, jamais d'AXFR.
- **Résolveur configurable** via `RECONAUT_DNS_RESOLVER` (forme `host:port`, par ex. `127.0.0.1:53` pour un Unbound local). À défaut, le résolveur système est utilisé.
- **Timeout par requête : 5 s** (configurable via `RECONAUT_DNS_TIMEOUT`, en secondes).
- **Zéro fuite hors scope** : si la cible n'est pas couverte par une entrée de scope active, le job est rejeté côté Rails avant d'être enqueueé (pas de validation côté worker — c'est le pacte `request_scan` actuel).

#### Scenario: Résolution d'un domaine dans le scope renvoie ses MX et NS
- **GIVEN** un opérateur a déclaré `domain:example.fr` dans son scope
- **AND** une clé API avec scope MCP `write:scans`
- **WHEN** la clé invoque `request_scan({"scan_kind":"dns_records","target_kind":"domain","target_value":"example.fr"})`
- **THEN** le serveur Rails enqueue un job sur `scan:dns_records`
- **AND** le worker `scanner-dns_records` consomme le job, émet une requête DNS par type (`A`, `AAAA`, `MX`, `NS`, `TXT`, `CAA`, `SOA`)
- **AND** un `ScanResultV1` est ingéré avec `findings` contenant un objet par enregistrement résolu (avec `record_type`, `name`, `value`, `ttl`)

#### Scenario: Domaine hors scope rejeté avant ingress worker
- **GIVEN** un opérateur dont le scope ne couvre PAS `example.org`
- **WHEN** la clé invoque `request_scan({"scan_kind":"dns_records","target_kind":"domain","target_value":"example.org"})`
- **THEN** Rails renvoie `{ ok: false, error: "out-of-scope" }` sans enqueuer de job
- **AND** aucune requête DNS n'est émise vers `example.org`
- **AND** le journal d'audit contient une ligne `outcome=out-of-scope`

#### Scenario: AXFR jamais tenté
- **GIVEN** un domaine cible, dans le scope
- **WHEN** le worker `scanner-dns_records` traite le job
- **THEN** un audit du code Go (test d'intégration ou linter) confirme qu'aucune requête de type AXFR n'est jamais formée
- **AND** un test unitaire stub le résolveur et assert qu'il est appelé pour les types `A`, `AAAA`, `MX`, `NS`, `TXT`, `CAA`, `SOA` mais JAMAIS pour `AXFR` ni `IXFR`

#### Scenario: Résolveur configuré pointe un Unbound interne
- **GIVEN** un opérateur a configuré `RECONAUT_DNS_RESOLVER=10.0.0.53:53` (Unbound interne)
- **WHEN** le worker `scanner-dns_records` démarre
- **THEN** toutes les requêtes DNS sortantes ciblent `10.0.0.53:53`
- **AND** un test contre un faux serveur DNS qui écoute sur ce port confirme que les requêtes y arrivent et que `8.8.8.8` ou autre résolveur public n'est pas joint

#### Scenario: Timeout par requête respecté
- **GIVEN** un résolveur lent qui ne répond jamais
- **WHEN** le worker tente de résoudre une zone
- **THEN** chaque requête abandonne après le `RECONAUT_DNS_TIMEOUT` configuré (défaut 5 s)
- **AND** le worker continue avec les autres types (un timeout sur `MX` ne bloque pas la résolution de `NS`)
- **AND** le `ScanResultV1` final porte `status="partial"` et liste les types qui ont effectivement réussi

#### Scenario: Idempotence d'une re-résolution
- **GIVEN** un job `dns_records` pour `example.fr` avec `idempotency_key="K"` déjà traité
- **WHEN** un nouveau job avec la même `idempotency_key="K"` est enqueuee
- **THEN** le worker (ou la couche d'ingestion) détecte le doublon
- **AND** aucune nouvelle écriture métier n'a lieu (cf. spec `integrations` Requirement: Inbound Integration via ScanResultV1)
- **AND** une ligne d'audit `outcome=duplicate` est écrite
