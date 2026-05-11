# Déploiement Kubernetes via Helm

Statut : **stable v0.1.0-dev** — images single-arch, unsigned (multi-arch + SBOM + signatures Sigstore → futur `add-oci-release`).
Audience : opérateur SRE qui déploie Reconaut sur un cluster Kubernetes.

Ce guide couvre l'installation, la configuration et la mise à jour de Reconaut via le chart Helm officiel sous [`deploy/helm/reconaut/`](https://github.com/banux/Reconaut/tree/main/deploy/helm/reconaut). Pour le détail interne du chart, voir le [README du chart](https://github.com/banux/Reconaut/blob/main/deploy/helm/reconaut/README.md).

## Pré-requis

- Kubernetes 1.27+
- Helm 3.12+
- **Postgres 16+** avec les extensions `timescaledb`, `vector` (pgvector), `age` (Apache AGE) installées et accessible depuis le namespace cible.
- Un registry où pousser les images `reconaut/api:0.1.0-dev` et `reconaut/scanner:0.1.0-dev` (cf. [Dockerfiles](https://github.com/banux/Reconaut/blob/main/apps/api/Dockerfile)).

## Installation minimale

```sh
# Pousse les images vers ton registry privé (exemple)
docker build -t myregistry.local/reconaut/api:0.1.0-dev apps/api/
docker build -t myregistry.local/reconaut/scanner:0.1.0-dev apps/scanner/
docker push myregistry.local/reconaut/api:0.1.0-dev
docker push myregistry.local/reconaut/scanner:0.1.0-dev

# Install
helm install reconaut deploy/helm/reconaut \
  --namespace reconaut --create-namespace \
  --set image.repository=myregistry.local/reconaut/api \
  --set scanner.image.repository=myregistry.local/reconaut/scanner \
  --set postgres.url='postgresql://reconaut:strong_password@postgres.svc.cluster.local:5432/reconaut_production' \
  --set auth.bootstrap.operatorPassword='nouveau-mdp-fort'
```

Le Job pré-install :

1. Joue `bundle exec rails db:migrate` contre le Postgres référencé (crée toutes les tables : scope, hosts, services, embeddings, audit_log, users, api_keys, …).
2. Joue `bundle exec rails reconaut:set_password` (idempotent — bootstrap l'opérateur unique).

## Vérification

```sh
kubectl -n reconaut get pods
kubectl -n reconaut logs job/reconaut-bootstrap
kubectl -n reconaut port-forward svc/reconaut-api 3000:3000

# Dans un autre terminal
curl -fsS http://localhost:3000/healthz
./reconautctl --url http://localhost:3000 login
```

## Variables clefs

Cf. [`values.yaml`](https://github.com/banux/Reconaut/blob/main/deploy/helm/reconaut/values.yaml) pour la liste exhaustive.

| Path                              | Défaut             | Quand l'overrider                                          |
|-----------------------------------|--------------------|------------------------------------------------------------|
| `postgres.url`                    | _(requis)_         | Toujours fournir une URL complète OU `host`+`password`.    |
| `auth.bootstrap.operatorPassword` | `changeme`         | **Toujours overrider** à la première install.              |
| `embedder.provider`               | `local`            | `ollama` / `mistral` / `openai-compatible` selon besoin.    |
| `mcp.tlsRequired`                 | `true`             | `false` SI mTLS est terminé au reverse proxy en amont.     |
| `ingress.enabled`                 | `false`            | `true` + cert-manager pour exposer sur internet.            |
| `networkPolicy.enabled`           | `false`            | `true` en déploiement air-gapped (cf. init §8.5).           |
| `exports.persistence.enabled`     | `false`            | `true` en prod (préserve `tmp/exports/` entre restarts).    |
| `scanner.replicas`                | `1`                | ≥ 2 quand la charge de scan augmente.                       |

## Sécurité : NetworkPolicy

```sh
helm upgrade reconaut deploy/helm/reconaut \
  --reuse-values \
  --set networkPolicy.enabled=true
```

Génère une `NetworkPolicy` qui restreint l'egress des pods Reconaut à :

- DNS interne k8s (kube-system, port 53 UDP/TCP)
- Postgres BYO sur son port
- Sidecar Ollama si `embedder.provider=ollama`

Tout autre egress est bloqué. Combinée avec `embedder.provider=local`, Reconaut tourne en **zéro-outbound** (cf. acceptance line init L242).

## Ingress + TLS automatique

Pré-requis : cert-manager installé sur le cluster avec un `ClusterIssuer` Let's Encrypt (ou autre).

```yaml
# values-prod.yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
  hosts:
    - host: reconaut.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: reconaut-tls
      hosts: [reconaut.example.com]

mcp:
  # L'ingress termine TLS et pose X-Forwarded-Proto: https — `required`
  # est OK : le middleware Reconaut accepte la connexion via le header.
  tlsRequired: true
```

```sh
helm upgrade reconaut deploy/helm/reconaut -f values-prod.yaml --reuse-values
```

## Mise à jour

```sh
git pull
helm upgrade reconaut deploy/helm/reconaut --reuse-values
```

Le Job `pre-upgrade` rejoue `db:migrate`. `set_password` reste idempotent — pas de rotation sauf `RECONAUT_ROTATE=true` (à passer manuellement via un override values temporaire).

## Désinstallation

```sh
helm uninstall reconaut --namespace reconaut
```

Les PVC ne sont pas supprimés automatiquement. Pour tout nettoyer :

```sh
kubectl -n reconaut delete pvc -l app.kubernetes.io/instance=reconaut
```

Le Postgres BYO n'est **jamais** touché par le `uninstall`.

## Bascule sur Ollama (embedder externe local)

Pré-requis : Ollama déployé séparément dans le cluster (chart bitnami/ollama ou similaire).

```sh
helm upgrade reconaut deploy/helm/reconaut \
  --reuse-values \
  --set embedder.provider=ollama \
  --set embedder.ollama.url='http://ollama.ollama-ns.svc.cluster.local:11434' \
  --set embedder.ollama.model='nomic-embed-text'

# Réindexe les hosts existants pour qu'ils utilisent le nouveau provider
kubectl -n reconaut exec deployment/reconaut-api -- \
  bundle exec rails reconaut:reindex RECONAUT_REINDEX_PURGE=true
```

Le `RECONAUT_REINDEX_PURGE=true` vide les anciennes embeddings du provider précédent (incompatibles avec la nouvelle dim/provider). Cf. [`embedding-pipeline.md`](embedding-pipeline.md).

## Troubleshooting

### `helm install` échoue avec `Missing required value: postgres.url ou postgres.host+password requis`

Tu n'as pas fourni d'URL Postgres. Au moins une option :

```sh
--set postgres.url='postgresql://...'
# ou
--set postgres.host='host' --set postgres.password='...'
```

### Le Job `reconaut-bootstrap` reste en `BackoffLimitExceeded`

```sh
kubectl -n reconaut logs job/reconaut-bootstrap
```

Causes fréquentes :

- Postgres injoignable depuis le namespace.
- Extension manquante (`CREATE EXTENSION timescaledb;` non joué côté Postgres).
- Privilèges insuffisants (`reconaut` n'a pas `CREATEDB` ou `SUPERUSER` pour les extensions).

### Les pods `scanner-*` redémarrent en boucle

Cause habituelle : pas de driver Postgres dans les binaires Go (cf. `apps/scanner/cmd/scanner-worker/db.go`, placeholder hérité). En attendant `add-scanner-pgx-driver` futur, lance les workers en mode `--dry-run` via un override :

```sh
helm upgrade reconaut deploy/helm/reconaut \
  --reuse-values \
  --set scanner.replicas=0
```

Le scan async ne fonctionnera pas, mais le reste (scope, search, agent_chat) tourne.

### `agent_chat` retourne `warnings: ["retriever-not-wired"]`

L'extension pgvector n'est pas chargée OU la table `embeddings` est absente. Vérifier côté Postgres :

```sql
SELECT * FROM pg_extension WHERE extname='vector';
-- doit retourner une ligne
\d embeddings
-- doit montrer une table avec colonne vector(384)
```

Si absent, c'est que `db:migrate` a échoué — relancer le Job bootstrap (`kubectl delete job reconaut-bootstrap && helm upgrade ...`).

## Liens

- [`deploy/helm/reconaut/README.md`](https://github.com/banux/Reconaut/blob/main/deploy/helm/reconaut/README.md) — README du chart, plus de détails.
- [`docs/operating/deployment-docker-compose.md`](deployment-docker-compose.md) — alternative pour dev local et déploiements simples.
- [`docs/operating/embedder-providers.md`](embedder-providers.md) — bascule providers d'embedding.
- [`docs/operating/embedding-pipeline.md`](embedding-pipeline.md) — pipeline d'indexation des hôtes.
- `openspec/changes/add-helm-chart/` — change qui livre ce chart.
