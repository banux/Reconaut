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

## Configuration des workers Go (RECONAUT_DATABASE_URL)

Depuis [`add-scanner-pgx-driver`](https://github.com/banux/Reconaut/blob/main/openspec/changes/add-scanner-pgx-driver/proposal.md), les binaires `scanner-<kind>` consomment la file `good_jobs` et écrivent leurs résultats dans la table `scan_results` via le pilote `pgx/v5/stdlib`. Chaque worker DOIT recevoir :

```sh
RECONAUT_DATABASE_URL=postgresql://reconaut:reconaut_dev_password@postgres:5432/reconaut_development?sslmode=disable
```

(En prod : `sslmode=require` minimum.) Sans cette variable, le worker exit non-zéro au démarrage avec un message `db ping: ...`. Le mode `--dry-run` court-circuite la DB et reste utile pour des tests d'intégration locaux.

Calibrage `max_connections` Postgres : chaque worker plafonne à **8 conns** (cf. `runtime.wireStores` : `SetMaxOpenConns(8)`). Avec 6 workers (`tcp_probe`, `tls_capture`, `http_banner`, `subdomain_enum`, `service_fingerprint`, `dns_records`), prévoir au minimum **48 conns + le pool Rails**. Le défaut Postgres est 100 — suffisant en dev local.

Migration de la table `scan_results` :

```sh
docker exec reconaut-api bundle exec rails db:migrate
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
