# Runbook : ajouter ou retirer un worker Go en production

Cette page decrit la procedure operationnelle pour scaler les workers
de scan Reconaut. Elle suppose que `apps/scanner/cmd/scanner-worker`
soit empaquete en binaire statique ou en image OCI multi-arch
(cf. `openspec/project.md` section *Distribution*).

Source de verite :
- `openspec/changes/add-tech-stack/specs/architecture/spec.md`
  - Requirement: Horizontal Distribution of Scan Workers
- `openspec/changes/add-tech-stack/tasks.md` section 6.2

## Principe

Les workers Go consomment `good_jobs` directement via
`SELECT ... FOR UPDATE SKIP LOCKED`. Aucun broker, aucun service de
coordination. Ajouter un worker = lancer un binaire de plus connecte
au meme cluster Postgres. Le verrou ligne garantit qu'un job est
traite par un seul worker a la fois.

## Ajouter N workers

### Avec docker-compose (dev / staging)

```sh
docker compose up -d --scale scanner=5 scanner
```

Les 5 instances pointent toutes sur le meme `DATABASE_URL` ; aucune
configuration partagee n'est requise.

### Avec systemd (bare-metal)

```sh
for i in 1 2 3 4 5; do
  systemctl start reconaut-scanner@$i
done
```

Le template unit `reconaut-scanner@.service` lit `DATABASE_URL` depuis
`/etc/reconaut/scanner.env` (meme cluster que l'API).

### Avec Kubernetes

```sh
kubectl scale deployment reconaut-scanner --replicas=5
```

Cf. chart Helm `charts/reconaut/templates/scanner-deployment.yaml`
(livre par le change `add-helm-chart`).

## Verifier qu'ils consomment

1. **Dashboard GoodJob cote Rails** : `/good_job` (montage par defaut).
   La page liste les jobs en cours, finis, en echec.
2. **Compteur Prometheus cote Go** :
   ```
   scan_worker_jobs_claimed_total{worker_id=...}
   ```
   Doit incrementer sur chaque worker. Si un worker affiche zero
   pendant > 60 s alors qu'il y a des jobs en file, vérifier que sa
   connexion Postgres est ouverte (`pg_stat_activity`).
3. **Histogramme de latence** :
   ```
   scan_worker_job_duration_seconds_bucket
   ```
   p95 par `scan_kind` doit rester sous la cible (ex. tcp_probe < 5 s).

## Retirer un worker proprement (drain)

Le binaire `scanner-worker` reagit aux signaux UNIX :

- `SIGTERM` : drain. Le worker arrete d'accepter de nouveaux jobs et
  finit ceux en cours (timeout par defaut 30 s, configurable via
  `RECONAUT_DRAIN_TIMEOUT_SECONDS`).
- `SIGINT` : interruption immediate (utile en dev). Les jobs en cours
  sont marques `error` et iront en retry GoodJob.
- `SIGKILL` : a éviter. Le worker mourra brutalement, les jobs en
  cours resteront verrouilles jusqu'au timeout `lock_timeout` Postgres,
  puis seront repris par un autre worker.

### Procedure recommandee

```sh
# 1. Stopper l'arrivee de nouveaux jobs sur ce worker
systemctl kill --signal SIGTERM reconaut-scanner@5

# 2. Attendre la fin du drain (max RECONAUT_DRAIN_TIMEOUT_SECONDS)
journalctl -fu reconaut-scanner@5 | grep -m1 'drain complete'

# 3. Stopper l'unit
systemctl stop reconaut-scanner@5
```

## Cas particuliers

- **Mise a jour rolling**. Demarrer N+1 workers de la nouvelle version,
  drainer un a un les anciens. La file de jobs continue a etre traitee.
- **Migration de schema de message**. Si on bump `schema_version` de 1
  a 2 sur `ScanJobV1`, deployer d'abord les workers v2 (qui acceptent
  v1 + v2), puis seulement basculer Rails pour emettre v2. Ce
  decouplage est garanti par le scenario "Evolution de schema" de
  `architecture/spec.md`.
- **Panique recurrente sur un kind**. Si un worker boucle en panic
  (compteur `scan_worker_panics_total{scan_kind=...}` > seuil), drain +
  remove ce worker, ouvrir un ticket sur le handler Go correspondant.

## Anti-patterns

- **Tuer SIGKILL en routine**. Verrouille la file le temps du
  `lock_timeout` (defaut 60 s) et augmente l'incident pour rien.
- **Scaler sans surveiller la charge Postgres**. Au-dela de ~20 workers
  par cluster Postgres, surveiller `pg_stat_database.numbackends` ;
  ajuster `RAILS_MAX_THREADS` et `RECONAUT_WORKER_POOL_SIZE` cote Go
  pour ne pas saturer le pool de connexions.
- **Pointer plusieurs workers sur des bases differentes**. La file de
  jobs est globale et stockee dans **un** Postgres. Tous les workers
  doivent partager exactement le meme `DATABASE_URL`.

## Tests d'execution

Le scenario "Plusieurs workers consomment la meme file" de
`architecture/spec.md` materialise ce runbook : 5 workers, 1000 jobs
en burst, charge repartie a moins de 30 % de variance autour de la
moyenne. Un test charge automatise `scripts/load_test_workers.sh`
(parqué jusqu'a ce qu'AGE et le worker boilerplate existent) executera
ce scenario en CI.
