# Exporter des données via le tool MCP `export_report`

Statut : **stable**.
Audience : opérateur ou agent IA externe qui consomme `POST /mcp/tools/export_report`.

L'outil MCP `export_report` permet d'exporter le scope, les hosts, les services ou les scans dans un format texte (`json`, `csv`, `stix2`) via une URL de téléchargement signée à durée de vie limitée. Cas d'usage typiques : alimenter un SIEM, archiver pour audit, échanger avec un outil externe (tableur, notebook).

## Principe

Reconaut ne renvoie pas le contenu de l'export inline dans la réponse MCP. Il génère un fichier sur disque sous `RECONAUT_EXPORT_DIR` (défaut `tmp/exports/`), retourne une URL `/mcp/exports/<uuid>` accompagnée d'un token HMAC-SHA256 et d'une date d'expiration. Le client fait ensuite un `GET` sur l'URL pour télécharger le fichier.

Trois propriétés clefs :

1. **One-shot** : le fichier est supprimé après le premier téléchargement réussi. Un retry après crash réseau doit re-générer l'export — cette politique réduit la fenêtre d'exposition d'un token volé.
2. **HMAC-SHA256 timing-safe** : le token est calculé sur `(uuid || expires_at_iso)` avec `Rails.application.secret_key_base` et vérifié via `Rack::Utils.secure_compare` côté serveur.
3. **TTL court** : 1 heure par défaut (`RECONAUT_EXPORT_TTL_S`). Au-delà, le fichier est considéré expiré ; un nettoyage best-effort s'exécute à chaque génération pour purger les exports orphelins (download abandonné, crash) plus vieux que 24h.

## Exemple complet

```sh
# 1. Demande d'export — retourne une URL signée
curl -X POST http://localhost:3000/mcp/tools/export_report \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "filter": { "kind": "hosts", "limit": 1000 },
    "format": "json"
  }'
```

Réponse 200 :

```json
{
  "tool": "export_report",
  "result": {
    "download_url": "/mcp/exports/abc123...?token=64hex...&expires_at=2026-05-10T15:30:00Z",
    "token": "64hex...",
    "expires_at": "2026-05-10T15:30:00Z",
    "format": "json",
    "record_count": 47,
    "kind": "hosts"
  }
}
```

```sh
# 2. Téléchargement (one-shot) — utilise download_url tel quel
curl -O "http://localhost:3000${DOWNLOAD_URL}"
```

Le client n'a pas besoin de reconstruire l'URL : `download_url` embarque déjà `token` et `expires_at` en query params.

## Formats disponibles

### `json`

Tableau plat des records sérialisé via `JSON.pretty_generate`. Content-Type : `application/json`.

```json
[
  { "id": "h1", "ip": "192.0.2.10", "fqdn": null, "first_seen_at": "2026-05-01", ... },
  { "id": "h2", "ip": null, "fqdn": "mail.example.fr", ... }
]
```

### `csv`

RFC4180-conforme : première ligne = headers, valeurs avec virgule quotées par `"`. Content-Type : `text/csv`.

```csv
id,ip,fqdn,first_seen_at,last_seen_at
h1,192.0.2.10,,2026-05-01,2026-05-09
h2,,mail.example.fr,2026-05-01,2026-05-09
```

### `stix2`

Bundle STIX2.1 minimal **SCO-only**. Content-Type : `application/stix+json;version=2.1`.

```json
{
  "type": "bundle",
  "id": "bundle--<uuid>",
  "objects": [
    { "type": "ipv4-addr", "id": "ipv4-addr--<uuid5>", "value": "192.0.2.10" },
    { "type": "domain-name", "id": "domain-name--<uuid5>", "value": "mail.example.fr" }
  ]
}
```

Mapping actuel :
- Host avec IP → `ipv4-addr`
- Host avec FQDN → `domain-name`
- Service → `network-traffic` avec `dst_port` et `protocols`
- Entrée de scope `cidr|ip` → `ipv4-addr`, `domain|host` → `domain-name`
- Scan → extension custom `x-reconaut-scan` (préfixe `x-` conforme STIX2)

**Limitations** : pas d'objets `indicator`, `relationship`, `sighting`, `malware`, `threat-actor`. Les `id` STIX sont des UUID5 déterministes (même input = même id, ce qui assure la cohérence inter-export). Mapping complet relève de `add-stix2-full-mapping` futur.

## Filtres disponibles

| Champ        | Type     | Effet                                                       |
|--------------|----------|-------------------------------------------------------------|
| `filter.kind`| `string` | `scope` \| `hosts` \| `services` \| `scans` (requis).        |
| `filter.limit` | `int`  | Nombre max de records (défaut 1000, max 10000).              |
| `format`     | `string` | `json` \| `csv` \| `stix2`.                                  |

Filtres riches (date range, country, service type) : différés à `add-export-filters`.

## Sécurité

- **Scope MCP requis** : `read:reports`. Une clé API qui n'a pas ce scope reçoit `403 rbac_forbidden`.
- **Token volé** : limité à 1 download dans la fenêtre TTL (1h). Un attaquant qui intercepte le token ne peut télécharger qu'une fois et seulement si l'opérateur n'a pas déjà téléchargé.
- **404 sur token invalide** : le serveur ne distingue pas « fichier inexistant » de « token erroné » dans la réponse — pas de leak d'existence.
- **Pas d'authentification utilisateur du download** : en mode mono-user, le token suffit. En multi-user (hors scope v1), il faudrait croiser token + identité du caller.

## Variables d'environnement

| Variable                  | Défaut             | Effet                                                |
|---------------------------|--------------------|------------------------------------------------------|
| `RECONAUT_EXPORT_DIR`     | `tmp/exports/`     | Répertoire de stockage des fichiers d'export.         |
| `RECONAUT_EXPORT_TTL_S`   | `3600` (1h)        | Durée de validité d'un token download.                |

## Liens

- `openspec/changes/add-mcp-engine/` — change qui livre l'outil.
- `openspec/changes/init-reconaut-platform/specs/mcp-server/spec.md` — spec parente (line 12).
- `openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md` — surface MCP canonique.
- [`docs/architecture/mcp-first.md`](../architecture/mcp-first.md) — architecture MCP-first globale.
