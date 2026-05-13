# Scanners distants (MCP-as-client)

Statut : **stable**.
Audience : opérateur qui veut déployer un worker `scanner-<kind>` hors de l'infra qui héberge Postgres — DMZ, edge géographique, infra client.

## Pourquoi ?

Reconaut est un outil d'ASM scope-driven, auto-hébergeable, single-user. L'un de ses usages naturels est de **scanner depuis plusieurs IPs publiques** (pour éviter d'avoir un seul point de visibilité), ou de **scanner l'intérieur d'un périmètre client** (depuis un agent posé chez lui, sans qu'il ait à exposer son réseau).

Pour rendre ces topologies possibles, les workers Go ne doivent **pas** avoir besoin d'accès direct à Postgres. Depuis [`remote-scanner-agents`](https://github.com/banux/Reconaut/blob/main/openspec/changes/remote-scanner-agents/proposal.md) (2026-05-13), c'est le cas :

- **Avant** : `scanner-<kind>` faisait `SELECT ... FOR UPDATE SKIP LOCKED` sur `good_jobs` et `INSERT ... ON CONFLICT` sur `scan_results` — il lui fallait creds Postgres + route réseau vers le port 5432.
- **Après** : `scanner-<kind>` appelle 3 tools MCP via HTTPS : `claim_scan_job`, `submit_scan_result`, `fail_scan_job`. Il n'a besoin que d'un outbound HTTPS vers Rails.

## Architecture

```
                                  ┌──────────────────────────┐
                                  │  Rails (apps/api)        │
                                  │                          │
   scanner-dns_records ──────────►│  MCP /tools/             │
   (DMZ ou edge)                  │    claim_scan_job        │
                                  │    submit_scan_result    │
   scanner-http_banner ──────────►│    fail_scan_job         │
   (infra client)                 │                          │
                                  │  ┌──────────────────┐    │
   scanner-tcp_probe ────────────►│  │ Postgres         │    │
   (cluster k8s)                  │  │  good_jobs       │    │
                                  │  │  scan_results    │    │
                                  │  │  scan_scope_…    │    │
                                  │  └──────────────────┘    │
                                  └──────────────────────────┘
```

Les workers parlent HTTPS+JSON à Rails. Rails est seul à toucher Postgres. Les workers s'authentifient avec une clé API portant les scopes `worker:claim` + `worker:submit`.

## Boucle worker

```
loop:
    job ← claim_scan_job(queue="scan:<kind>", worker_id=...)
    if job.empty:
        sleep(idle_backoff)
        continue
    result, err ← handler(job)   # le sondeur local (sshprobe, dnsprobe, …)
    if err:
        fail_scan_job(job.id, err.message)
    else:
        submit_scan_result(job.id, idempotency_key, status, target, observed_at)
```

Polling court (défaut 1 s d'idle backoff). Long polling possible mais non-implémenté en v1 (coût Puma plus élevé pour un gain marginal sur l'instance single-user typique).

## Configuration

Variables d'environnement reconnues par chaque binaire `scanner-<kind>` :

| Variable | Obligatoire | Description |
|---|---|---|
| `RECONAUT_API_URL` | oui (sauf `--dry-run`) | URL Rails, ex. `https://reconaut.example.com` |
| `RECONAUT_API_KEY` | oui (sauf `--dry-run`) | Clé API avec scopes `worker:claim` + `worker:submit` |
| `RECONAUT_WORKER_ID` | non | Défaut `<kind>-<hostname>-<pid>` |
| `RECONAUT_API_TLS_INSECURE` | non | `true`/`1` pour ignorer cert serveur invalide — **dev only** |
| `RECONAUT_<KIND>_PROBE_TIMEOUT` | non | Timeout de la sonde (varie par protocole) |

## Sécurité

- **Clé API scopée**. Une clé worker ne porte QUE `worker:claim` + `worker:submit`. Elle ne peut PAS appeler `add_scope`, `request_scan`, `agent_chat`, etc. Compromission limitée à la file de jobs (lecture des targets + écriture de résultats).
- **Rotation**. Révoquer une clé worker = un `revoke_api_key` côté Rails. Le worker exit à la prochaine 401 et le pod redémarre — un nouveau pod ne re-claim qu'avec une nouvelle clé.
- **Audit total**. Chaque `claim`/`submit`/`fail` produit une ligne `agent_audit` avec `caller_id` = identifiant de la clé. On peut voir quel worker a traité quel job, quand, et avec quel outcome.
- **Scope check côté Rails uniquement**. Le worker ne re-vérifie pas la cible — Rails le fait au moment du claim. Tradeoff : si le scope est révoqué entre claim et probe (fenêtre ≤ lease 5 min), le probe peut atterrir. Acceptable car Rails vérifie aussi à enqueue.
- **TLS**. En prod, `RECONAUT_API_URL` DOIT être en `https://`. Le serveur Rails impose `RECONAUT_MCP_TLS_REQUIRED=true` par défaut en environnement production.

## Topologies typiques

### A. Tout co-localisé (dev local)

```sh
# docker-compose : api + postgres + scanners dans le même réseau Docker
docker compose up
```

Workers parlent `http://api:3000` — pas de TLS, pas de sortance réseau.

### B. Cluster K8s mono-namespace (par défaut Helm)

```yaml
scanner:
  apiUrl: "http://reconaut-api:8080"
  apiKey: "<clé worker>"
  replicas: 1
```

NetworkPolicy peut limiter egress à `api-svc:8080` + l'inventaire des targets.

### C. Workers en DMZ ou edge

```yaml
# values.yaml du chart "scanner-only" (futur) ou env du binaire :
RECONAUT_API_URL=https://reconaut.example.com
RECONAUT_API_KEY=<clé worker>
```

Le pod tourne dans un namespace qui n'a PAS de route vers Postgres. Outbound HTTPS uniquement.

### D. Worker chez un client

L'opérateur génère une clé worker dédiée (`label=client-X-fra1`), la transmet de manière sécurisée, et le client lance :

```sh
docker run -e RECONAUT_API_URL=https://reconaut.example.com \
           -e RECONAUT_API_KEY=<clé> \
           reconaut/scanner:latest scanner-dns_records
```

Le client peut révoquer son worker en supprimant le conteneur ; l'opérateur peut révoquer la clé à distance.

## Quand un worker crashe

Le contrat **at-least-once** est préservé :

1. Rails set `good_jobs.performed_at = NOW()` au claim → lease de 5 min implicite.
2. Si le worker ne fait pas `submit_scan_result` ou `fail_scan_job` dans les 5 min, le job `LeaseReleaseJob` (recurring, toutes les 60 s) remet `performed_at = NULL`.
3. Un autre worker (ou le même redémarré) re-claim le job.
4. L'`idempotency_key` du payload garantit que même si le job est exécuté 2 fois, `scan_results` ne contient qu'une seule ligne.

## Migration depuis l'ancien modèle

Aucun rollback de schéma DB. Pour un opérateur qui tournait sur l'ancienne archi :

1. Mettre à jour les images `reconaut-api` et `reconaut/scanner` à la version qui inclut `remote-scanner-agents`.
2. Provisionner une clé worker (`reconautctl agent-keys create --scopes worker:claim,worker:submit`).
3. Mettre à jour le manifest/compose des scanners pour retirer `RECONAUT_DATABASE_URL` et ajouter `RECONAUT_API_URL` + `RECONAUT_API_KEY`.
4. `helm upgrade` (ou `docker compose up -d`). Pas de migration applicative — les anciennes lignes `scan_results` restent lisibles.

## Liens

- [`remote-scanner-agents`](https://github.com/banux/Reconaut/blob/main/openspec/changes/remote-scanner-agents/proposal.md) — proposal complète.
- [`scan-frontier.md`](scan-frontier.md) — principes intangibles du périmètre scan.
- [`deployment-helm.md`](../operating/deployment-helm.md) — déploiement K8s.
- [`deployment-docker-compose.md`](../operating/deployment-docker-compose.md) — déploiement docker-compose.
