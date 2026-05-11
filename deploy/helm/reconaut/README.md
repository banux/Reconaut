# Chart Helm Reconaut

Chart Helm officiel pour déployer Reconaut sur Kubernetes (1.27+).

**Statut : v0.1.0-dev** — single-arch, unsigned. Les images multi-arch + SBOM + signatures Sigstore arriveront avec `add-oci-release`.

## Pré-requis

- Kubernetes 1.27+
- Postgres 16+ accessible depuis le cluster (BYO — l'opérateur fournit son cluster avec extensions TimescaleDB + pgvector + Apache AGE).
- Images Reconaut buildées et accessibles dans un registry joignable :
  - `reconaut/api:0.1.0-dev` (cf. `apps/api/Dockerfile`)
  - `reconaut/scanner:0.1.0-dev` (cf. `apps/scanner/Dockerfile`)

## Installation

```sh
# 1. Bootstrap : fournir au minimum l'URL Postgres et le mot de passe opérateur.
helm install reconaut deploy/helm/reconaut \
  --set postgres.url='postgresql://reconaut:strong_password@postgres.local:5432/reconaut_production' \
  --set auth.bootstrap.operatorPassword='changeme-please'

# 2. Helm execute le Job pre-install qui lance db:migrate + set_password.

# 3. Vérifier l'install
kubectl get pods -l app.kubernetes.io/instance=reconaut
kubectl logs job/reconaut-bootstrap

# 4. Port-forward pour tester
kubectl port-forward svc/reconaut-api 3000:3000
curl -fsS http://localhost:3000/healthz
```

## Valeurs principales

| Path                              | Défaut             | Effet                                                          |
|-----------------------------------|--------------------|----------------------------------------------------------------|
| `postgres.url`                    | _(requis)_         | URL Postgres complète, OU utiliser `postgres.host` + champs.    |
| `auth.bootstrap.operatorPassword` | `changeme`         | Mot de passe opérateur initial (à overrider impérativement).    |
| `embedder.provider`               | `local`            | `local` (zéro réseau) / `ollama` / `mistral` / `openai-compatible`. |
| `mcp.tlsRequired`                 | `true`             | Refuse le clair. Terminer TLS à l'ingress.                      |
| `ingress.enabled`                 | `false`            | Activer pour exposer via Ingress (cert-manager recommandé).      |
| `networkPolicy.enabled`           | `false`            | Opt-in pour air-gapped : limite egress aux dépendances.          |
| `scanner.replicas`                | `1`                | Replicas par scan_kind (6 Deployments au total).                 |
| `exports.persistence.enabled`     | `false`            | PVC pour `tmp/exports/` (recommandé en prod).                    |

Liste complète : `helm show values deploy/helm/reconaut`.

## Bascule sur Ollama (embedder externe)

```sh
helm upgrade reconaut deploy/helm/reconaut \
  --reuse-values \
  --set embedder.provider=ollama \
  --set embedder.ollama.url='http://ollama.ollama-ns.svc.cluster.local:11434' \
  --set embedder.ollama.model='nomic-embed-text'
```

Le sidecar Ollama lui-même n'est pas géré par ce chart — l'opérateur le déploie séparément (souvent via le chart bitnami/ollama ou une CRD dédiée).

## Air-gapped

```sh
helm upgrade reconaut deploy/helm/reconaut \
  --reuse-values \
  --set networkPolicy.enabled=true \
  --set embedder.provider=local \
  --set mcp.tlsRequired=false
```

La `NetworkPolicy` rendue limite l'egress à : DNS k8s + Postgres référencé + sidecar Ollama (si `provider=ollama`).

## Activer Ingress + TLS via cert-manager

```yaml
# values-ingress.yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "32m"
  hosts:
    - host: reconaut.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: reconaut-tls
      hosts: [reconaut.example.com]
```

```sh
helm upgrade reconaut deploy/helm/reconaut -f values-ingress.yaml --reuse-values
```

## Subchart Postgres optionnel

Le chart **ne dépend pas** d'un Postgres embarqué (BYO recommandé). Pour un environnement de test rapide, ajouter une dependency :

```yaml
# Chart.yaml (override locale)
dependencies:
  - name: postgresql
    version: 16.x.x
    repository: https://charts.bitnami.com/bitnami
    condition: postgresql.enabled
```

Puis dans `values.yaml` :

```yaml
postgresql:
  enabled: true
  auth:
    database: reconaut_production
    username: reconaut
    password: "..."
postgres:
  external: false
  host: "{{ .Release.Name }}-postgresql"
```

Reconaut **n'inclut pas** ce subchart par défaut pour ne pas masquer les besoins HA/backup d'un cluster Postgres prod.

## Mise à jour

```sh
helm upgrade reconaut deploy/helm/reconaut --reuse-values
```

Le Job `pre-upgrade` rejoue `db:migrate` puis `set_password` (idempotent — pas de rotation sauf si `RECONAUT_ROTATE=true`).

## Désinstallation

```sh
helm uninstall reconaut
```

Les PVC ne sont pas supprimés par défaut (préserve `tmp/exports/`). Supprimer manuellement :

```sh
kubectl delete pvc reconaut-exports
```

Le Postgres BYO n'est jamais touché par le `helm uninstall`.

## Troubleshooting

### Le pod `reconaut-bootstrap` reste en `Error`

Probable cause : `postgres.url` ne pointe pas vers une instance joignable, ou les extensions (TimescaleDB / pgvector / AGE) ne sont pas installées.

```sh
kubectl logs job/reconaut-bootstrap
```

### `kubectl logs deployment/reconaut-api` affiche `[agent] pipeline not wired`

La table `embeddings` n'existe pas — `bundle exec rails db:migrate` n'a pas été joué, ou les extensions Postgres ne sont pas chargées. Rejouer le Job bootstrap :

```sh
kubectl delete job reconaut-bootstrap
helm upgrade reconaut deploy/helm/reconaut --reuse-values
```

### `helm template` échoue avec `Missing required value: postgres.url ou postgres.host+password requis`

Tu n'as pas fourni d'URL Postgres. Au moins une de ces deux options est requise :

```sh
--set postgres.url='postgresql://...'
# ou
--set postgres.host='postgres.local' --set postgres.password='...'
```

## Liens

- [`docs/operating/deployment-helm.md`](../../../docs/operating/deployment-helm.md) — guide opérateur complet.
- [`openspec/changes/add-helm-chart/`](../../../openspec/changes/add-helm-chart/) — change qui livre ce chart.
- `apps/api/Dockerfile`, `apps/scanner/Dockerfile` — Dockerfiles consommés par les Deployments.
