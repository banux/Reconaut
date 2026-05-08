# Intégrer des scanners externes

Reconaut est conçu comme une **base de connaissance d'actifs internet** alimentée par plusieurs sources : ses propres workers Go, mais aussi des scanners tiers (nmap, nuclei, Censys exports, certificate transparency feeds, etc.) que l'opérateur fait pousser dans la base.

L'intégration entrante passe par un seul outil MCP : **`ingest_scan_result`**.

## Principe

L'outil externe doit produire un payload conforme au schéma JSON canonique [`packages/job-schema/scan_result_v1.json`](../../packages/job-schema/scan_result_v1.json) (`ScanResultV1`) — le même que les workers Go internes émettent. Aucun format alternatif n'est accepté en v1, c'est volontaire (discipline de schéma).

Le payload est ensuite envoyé via MCP HTTP+SSE en invoquant l'outil `ingest_scan_result`, avec une clé API personnelle scopée au minimum `write:scans`.

### Contraintes

- La cible (`payload.target`) DOIT être couverte par une entrée de scope active. Les ingestions hors scope sont refusées avec `out-of-scope` (mêmes règles que `request_scan`).
- L'`idempotency_key` du payload sert à dédupliquer les réinjections : un même `idempotency_key` rejoué retourne `outcome: "duplicate"` sans réécriture.
- Le champ optionnel `source` distingue l'origine (`"nmap"`, `"nuclei"`, etc.). Sans valeur, il est défaulté à `"external"`.

### Cas particulier : DNS records depuis dig / cli maison

Un opérateur qui exécute `dig` (ou un wrapper Python autour de `dnspython`) peut formater le résultat comme un `ScanResultV1` avec `scan_kind="dns_records"` et `findings` typés `dns_record`. C'est exactement le même format que celui émis par le binaire interne `scanner-dns_records` (cf. change [`add-dns-records-scanner`](../../openspec/changes/add-dns-records-scanner/proposal.md)) — la couche d'ingestion `Reconaut::ScanResultIngestor` ne distingue pas l'origine, seul le champ `source` change (`"internal"` vs `"dig"` / `"dnspython"` / etc.).

## Exemple : pousser un résultat nmap minimal

Supposons qu'un script wrapper a parsé une sortie nmap et construit le payload `ScanResultV1` suivant :

```json
{
  "schema_version": 1,
  "job_id": "nmap-20260508-001",
  "idempotency_key": "nmap-20260508-001-192-0-2-10",
  "target": { "kind": "ip", "value": "192.0.2.10" },
  "status": "success",
  "observed_at": "2026-05-08T12:00:00Z",
  "findings": [
    { "port": 22, "protocol": "tcp", "service": "ssh", "banner": "OpenSSH_8.9" },
    { "port": 443, "protocol": "tcp", "service": "https", "tls": { "subject": "example.test" } }
  ],
  "source": "nmap"
}
```

L'opérateur l'invoque via MCP en utilisant une clé API scopée `write:scans` :

```sh
curl -X POST https://reconaut.example.test/mcp/tools/ingest_scan_result \
  -H "Authorization: Bearer $RECONAUT_INGEST_KEY" \
  -H "Content-Type: application/json" \
  -d @nmap-result.json
```

Réponse attendue (happy path) :

```json
{
  "ok": true,
  "outcome": "ingested",
  "idempotency_key": "nmap-20260508-001-192-0-2-10",
  "job_id": "nmap-20260508-001",
  "source": "nmap"
}
```

## Émettre une clé API d'ingestion à scope minimal

Bonne pratique : ne PAS donner au wrapper externe une clé full-scope. Émettre une clé dédiée scopée uniquement `write:scans` :

```sh
reconautctl api-keys create --scopes write:scans --description "wrapper nmap"
# Affiche la clé une seule fois ; stockez-la dans le secret manager du wrapper.
```

Cette clé ne peut ni muter le scope (`write:scopes` manquant), ni lire les hôtes (`read:hosts` manquant), ni révoquer une autre clé. Elle ne sert qu'à pousser des résultats.

## Codes d'erreur

| Erreur | Cause | Action |
|--------|-------|--------|
| `invalid_payload` | Payload non conforme à `ScanResultV1` | Voir le champ `errors` pour les règles JSON Schema violées |
| `out-of-scope` | Cible hors du scope déclaré | Ajouter une entrée de scope (`reconautctl scope add`) avant l'ingestion |
| `unauthorized` | Clé API sans scope `write:scans` | Émettre une nouvelle clé avec le scope ad hoc |

## Provenance des données

Reconaut conserve la trace de chaque source via le champ `source` propagé jusqu'aux outils de lecture (`search_hosts`, `get_host`). Un même hôte peut avoir plusieurs sources (`["internal", "nmap"]`) si à la fois un worker interne et un scanner externe l'ont observé. L'agent conversationnel (et tout agent IA externe) cite la source dans ses réponses pour permettre à l'opérateur de remonter à l'origine d'une observation.

## Connecteurs prêts-à-l'emploi

En v1, Reconaut ne livre **aucun** connecteur prêt-à-l'emploi. Chaque opérateur écrit son adapter (script Bash + `jq`, script Python, gem Ruby, etc.) qui produit `ScanResultV1` à partir de la sortie de son scanner. Des connecteurs de référence pourront être livrés dans des changes ultérieurs (`add-nmap-import`, `add-nuclei-import`, etc.).

## Voir aussi

- [`packages/job-schema/scan_result_v1.json`](../../packages/job-schema/scan_result_v1.json) — schéma canonique
- [`openspec/changes/reposition-as-agent-knowledge-base/`](../../openspec/changes/reposition-as-agent-knowledge-base/) — change qui acte le repositionnement « base de connaissance pour agents »
- [`openspec/changes/mcp-as-primary-entrypoint/`](../../openspec/changes/mcp-as-primary-entrypoint/) — change qui acte MCP comme canal canonique
