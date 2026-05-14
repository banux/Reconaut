# Déploiement local via docker-compose

Statut : **stable**.
Audience : opérateur qui veut faire tourner Reconaut sur sa machine ou un serveur unique (lab interne, démo, dev local).

Le `docker-compose.yml` racine démarre la stack complète (Postgres + Rails API + 6 scanner workers Go) en une commande. C'est la voie la plus simple pour évaluer ou héberger Reconaut sans cluster Kubernetes.

Pour Kubernetes, voir [`deployment-helm.md`](deployment-helm.md).

## Pré-requis

- Docker 24+
- Docker Compose v2 (intégré au CLI Docker récent)
- 2 GB RAM dispos pour les conteneurs (Postgres + Rails + 6 scanners)
- Port `5432` et `3000` libres sur `127.0.0.1`

## Démarrage en 3 commandes

```sh
git clone https://github.com/banux/Reconaut.git
cd Reconaut

# Build les images locales (Rails + scanner)
docker compose build

# Démarre tout
docker compose up -d

# Attends que le healthcheck Rails passe (< 60s)
curl -fsS http://localhost:3000/healthz
# → 200 OK
```

Tu peux maintenant pointer la TUI vers cette instance :

```sh
cd apps/tui && go build -o reconautctl ./cmd/reconautctl
RECONAUT_URL=http://localhost:3000 RECONAUT_PASSWORD=changeme ./reconautctl login
./reconautctl doctor
```

Le mot de passe initial de l'opérateur est `changeme` (cf. `docker-compose.yml` → `RECONAUT_OPERATOR_PASSWORD`). **Change-le immédiatement** via :

```sh
docker exec reconaut-api \
  env RECONAUT_OPERATOR_PASSWORD='mon-mdp-fort' RECONAUT_ROTATE=true \
  bundle exec rails reconaut:set_password
```

## Services lancés

| Service                             | Image                         | Port (loopback) | Rôle                                 |
|-------------------------------------|-------------------------------|-----------------|--------------------------------------|
| `postgres`                          | `reconaut/postgres:dev`       | `5432`          | Postgres + TimescaleDB + pgvector + AGE |
| `api`                               | `reconaut/api:0.1.0-dev`      | `3000`          | Rails + MCP HTTP+SSE                  |
| `scanner-tcp_probe`                 | `reconaut/scanner:0.1.0-dev`  | -               | Worker TCP probe                      |
| `scanner-tls_capture`               | `reconaut/scanner:0.1.0-dev`  | -               | Worker TLS capture                    |
| `scanner-http_banner`               | `reconaut/scanner:0.1.0-dev`  | -               | Worker HTTP banner                    |
| `scanner-subdomain_enum`            | `reconaut/scanner:0.1.0-dev`  | -               | Worker subdomain enum                 |
| `scanner-service_fingerprint`       | `reconaut/scanner:0.1.0-dev`  | -               | Worker SSH fingerprint                |
| `scanner-dns_records`               | `reconaut/scanner:0.1.0-dev`  | -               | Worker DNS records                    |

Pas de Redis / RabbitMQ / NATS / Kafka (GoodJob backed-by-Postgres = file unique). Pas de MinIO / S3 (exports MCP sur le volume `exports_data`). Pas d'Ollama imposé.

## Activer Ollama (embedder externe local)

L'embedder par défaut (`local`, encodage SHA-256-projeté) ne fait **aucun appel réseau** mais n'a **pas de sens sémantique**. Pour des recherches en langage naturel utiles, active Ollama via le fichier override d'exemple :

```sh
cp docker-compose.override.yml.example docker-compose.override.yml
docker compose up -d

# Pull le modèle d'embedding au premier démarrage (~250 MB)
docker exec reconaut-ollama ollama pull nomic-embed-text

# Reindex les hosts existants pour qu'ils utilisent Ollama
docker exec reconaut-api \
  env RECONAUT_REINDEX_PURGE=true bundle exec rails reconaut:reindex
```

Cf. [`embedder-providers.md`](embedder-providers.md) pour les autres options (Mistral cloud, OpenAI-compatible).

## Logs et debug

```sh
# Logs en direct
docker compose logs -f api
docker compose logs -f scanner-tcp_probe

# État des conteneurs (healthcheck)
docker compose ps

# Inspecter Postgres
docker exec -it reconaut-postgres psql -U reconaut -d reconaut_development
```

## Persistance des données

Deux volumes Docker :

- `postgres_data` : toutes les données applicatives (hosts, services, scans, scan_results, embeddings, audit_log, users, api_keys).
- `exports_data` : exports MCP générés par le tool `export_report` (téléchargement one-shot).

Backup :

```sh
# Dump Postgres complet
docker exec reconaut-postgres pg_dump -U reconaut reconaut_development > backup.sql

# Restore
docker exec -i reconaut-postgres psql -U reconaut reconaut_development < backup.sql
```

## Configuration des workers Go (clé API MCP)

Depuis [`remote-scanner-agents`](https://github.com/banux/Reconaut/blob/main/openspec/changes/remote-scanner-agents/proposal.md), les binaires `scanner-<kind>` **n'accèdent plus à Postgres**. Ils dialoguent uniquement avec Rails via MCP HTTPS. Chaque worker reçoit :

```sh
RECONAUT_API_URL=http://api:3000           # URL Rails (HTTPS en prod)
RECONAUT_API_KEY=<clé scoped:worker:claim,worker:submit>
RECONAUT_WORKER_ID=<optionnel — défaut hostname+pid>
```

Sans `RECONAUT_API_KEY`, le worker exit non-zéro avec un message `RECONAUT_API_KEY required (pass --dry-run to boot without a backend)`. Le mode `--dry-run` court-circuite tout l'I/O réseau et reste utile pour smoke tests.

**Provisionner la clé worker** (depuis l'hôte Rails) :

```sh
# Crée une clé API portant les 2 scopes worker:* — à reporter dans
# RECONAUT_WORKER_API_KEY de l'env compose.
docker exec reconaut-api bundle exec rails reconaut:agent_key:create \
  scopes=worker:claim,worker:submit label=docker-local
```

Migration de la table `scan_results` (toujours nécessaire — c'est Rails qui y écrit désormais), et de la table `good_jobs` (file ActiveJob — cf. `add-good-job-install`) :

```sh
docker exec reconaut-api bundle exec rails db:migrate
```

Les workers Go ne touchent jamais à ces tables directement (cf. `remote-scanner-agents`), c'est Rails qui dialogue avec Postgres via les use cases `Scanner::ClaimJob` / `SubmitResult` / `FailJob`.

**Topologies remote** : un worker peut tourner sur une autre machine que celle qui héberge Postgres. Il suffit de pointer `RECONAUT_API_URL` vers l'URL publique de Rails et d'injecter une clé API scopée. Aucun flux Postgres ne sort du serveur central.

## Cron & maintenance (LeaseReleaseJob)

Depuis [`add-good-job-cron-config`](https://github.com/banux/Reconaut/blob/main/openspec/changes/add-good-job-cron-config/proposal.md), GoodJob tourne en mode `:async` **dans le process Puma** (pas de service séparé en v1). Le seul cron schédulé est `LeaseReleaseJob`, qui s'exécute **chaque minute** pour re-queue les jobs scan dont le lease worker a expiré (>5 min) — garantit le contrat at-least-once de `remote-scanner-agents`.

Aucune action côté docker-compose : le job s'active automatiquement quand le service `api` boot.

Pour vérifier en local que le cron tourne :

```sh
docker exec reconaut-api bundle exec rails runner \
  "puts Rails.application.config.good_job.cron.inspect"
# → {lease_release: {cron: "* * * * *", class: "LeaseReleaseJob", ...}}
```

## Mise à jour

```sh
git pull
docker compose build
docker compose up -d
```

Les migrations Rails (`db:migrate`) ne sont **pas** lancées automatiquement à chaque restart en docker-compose. Pour rejouer :

```sh
docker exec reconaut-api bundle exec rails db:migrate
```

## Arrêt et nettoyage

```sh
# Arrête sans supprimer les volumes (préserve les données)
docker compose down

# Arrête ET supprime les volumes (DESTRUCTIF : perd toutes les données)
docker compose down -v
```

## Limitations du déploiement docker-compose

- **Mono-host** : tous les services tournent sur la même machine. Pas de HA, pas de répartition de charge.
- **Postgres local** : pas de réplication, pas de backup automatique. Adapter en monitoring + cron de dump si tu utilises ce setup en prod.
- **Pas de TLS terminé en amont** : `RECONAUT_MCP_TLS_REQUIRED=false` est posé dans le compose. Pour exposer publiquement, ajoute un reverse proxy (nginx, traefik, caddy) qui termine TLS — et passe à Helm + Ingress + cert-manager (cf. [`deployment-helm.md`](deployment-helm.md)).
- **Scanners workers limités à 1 replica par scan_kind**. Pour scaler, soit ajuste le compose (replicas YAML 2.4+), soit passe à Helm.

## Troubleshooting

### `docker compose up -d` ne démarre pas le service `api`

```sh
docker compose logs api | tail -50
```

Causes fréquentes :

- Build d'image échoué (`bundle install` qui tombe sur une gem indisponible offline). Vérifier `docker compose build` séparément.
- Postgres pas encore healthy. `depends_on` attend mais peut timeout — augmenter `healthcheck.retries` dans le compose.

### `curl http://localhost:3000/healthz` retourne `connection refused`

Le port 3000 est mappé sur `127.0.0.1` uniquement (pas `0.0.0.0`). Depuis une autre machine, utilise un reverse proxy ou modifie le mapping :

```yaml
# docker-compose.override.yml
services:
  api:
    ports:
      - "0.0.0.0:3000:3000"
```

### `agent_chat` retourne `warnings: ["retriever-not-wired"]`

Le pipeline d'embedding n'est pas câblé — souvent parce que `db:migrate` n'a pas créé la table `embeddings`. Vérifier :

```sh
docker exec reconaut-api bundle exec rails db:migrate:status | tail -10
docker exec reconaut-api bundle exec rails runner 'puts Embedding.table_exists?'
```

Si `false`, rejoue `db:migrate` puis redémarre `api` :

```sh
docker exec reconaut-api bundle exec rails db:migrate
docker compose restart api
```

## Liens

- [`deployment-helm.md`](deployment-helm.md) — déploiement Kubernetes via Helm (recommandé pour la prod).
- [`embedder-providers.md`](embedder-providers.md) — configurer un embedder externe.
- [`embedding-pipeline.md`](embedding-pipeline.md) — pipeline d'indexation.
- [`agent-chat-streaming.md`](agent-chat-streaming.md) — format SSE de l'agent.
- [`docs/usage/reconautctl.md`](../usage/reconautctl.md) — piloter Reconaut depuis la TUI.
- `openspec/changes/add-helm-chart/` — change qui livre Dockerfiles + chart + compose étendu.
