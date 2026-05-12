# Spec delta : platform

## ADDED Requirements

### Requirement: Workers déployables sans accès Postgres
Les binaires `scanner-<kind>` DOIVENT pouvoir s'exécuter dans un environnement où Postgres n'est PAS joignable, à condition que :

- `RECONAUT_API_URL` pointe vers une instance Rails Reconaut joignable en HTTPS.
- `RECONAUT_API_KEY` porte les scopes `worker:claim` (minimum) et `worker:submit`.
- Le réseau permet un outbound HTTPS vers `RECONAUT_API_URL` (port 443 en prod, port custom en dev).

Aucun autre flux réseau n'est requis côté worker (sauf bien sûr les flux vers les cibles à scanner — TCP/22, /80, /443, /3389, etc. selon le `scan_kind`). Conséquences opérationnelles :

- **Helm chart** : les pods `scanner-<kind>` n'ont plus le Secret `reconaut-db-credentials` monté. La NetworkPolicy peut limiter leur egress à `api-svc:443` + l'inventaire des cibles.
- **docker-compose** : les services `scanner-<kind>` n'ont plus `depends_on: [postgres]` ni `environment: RECONAUT_DATABASE_URL`. Ils ne dépendent que de `api`.
- **Topologies remote** : un worker peut tourner sur un serveur DMZ, dans l'infra d'un client, ou sur un edge node géographique avec uniquement un outbound HTTPS — pas besoin de tunneler Postgres.

#### Scenario: worker dans un namespace sans NetworkPolicy vers Postgres
- **GIVEN** un cluster Kubernetes avec une NetworkPolicy qui interdit egress vers `postgres-svc:5432` depuis le namespace `scanner-edge`
- **WHEN** un pod `scanner-dns_records` est déployé dans ce namespace avec `RECONAUT_API_URL=https://api-svc.reconaut/`
- **THEN** le pod démarre, claim des jobs, traite et submit normalement
- **AND** un test au tcpdump (ou `netstat -an`) confirme qu'AUCUNE conn vers le port 5432 n'est jamais ouverte

#### Scenario: worker derrière un NAT chez un client
- **GIVEN** un worker déployé sur un VPS client qui n'a pas de route vers le Postgres Reconaut
- **WHEN** le VPS lance le binaire `scanner-tcp_probe` avec `RECONAUT_API_URL=https://reconaut.exemple.fr` (URL publique) + `RECONAUT_API_KEY=<scoped>`
- **THEN** le worker établit une conn HTTPS sortante vers `reconaut.exemple.fr:443` et boucle correctement
- **AND** l'opérateur peut voir les jobs claim'és par ce worker dans l'audit log (caller_id = clé API du worker)

#### Scenario: variable RECONAUT_DATABASE_URL ignorée par le worker
- **GIVEN** un binaire scanner-* lancé avec `RECONAUT_DATABASE_URL=postgresql://wrong:wrong@localhost:5432/wrong`
- **WHEN** il démarre
- **THEN** il N'utilise PAS cette variable (pas d'erreur, pas de tentative de connexion)
- **AND** un test grep dans `apps/scanner/` confirme que `RECONAUT_DATABASE_URL` n'apparaît plus dans le code

## MODIFIED Requirements

### Requirement: Configuration env des binaires scanner-<kind>
Les variables d'environnement reconnues par les binaires `scanner-<kind>` sont :

**Obligatoires (sauf en `--dry-run`)** :
- `RECONAUT_API_URL` — URL de base du serveur Rails (ex. `https://reconaut.example.com`).
- `RECONAUT_API_KEY` — clé API avec scopes `worker:claim` et `worker:submit`.

**Optionnelles** :
- `RECONAUT_WORKER_ID` — identifiant logique du worker (défaut : `hostname + pid`).
- `RECONAUT_API_TLS_INSECURE` — `true`/`1` pour accepter un cert serveur invalide (dev uniquement).
- `RECONAUT_<KIND>_PROBE_TIMEOUT` — timeout des sondes par protocole (inchangé).
- `RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE` — inchangé.

**Retirées** :
- `RECONAUT_DATABASE_URL` — n'est plus consommée par les workers. **Conservée côté Rails** (la DB reste source de vérité).

#### Scenario: worker démarre avec env minimal valide
- **GIVEN** `RECONAUT_API_URL`, `RECONAUT_API_KEY` exportés
- **WHEN** le binaire est lancé sans flag
- **THEN** il démarre, log `scanner-<kind> started (api=<url>, worker_id=<id>)` et entre dans la boucle de claim

#### Scenario: worker sans RECONAUT_API_KEY → fail-fast
- **GIVEN** `RECONAUT_API_URL` exporté mais pas `RECONAUT_API_KEY`
- **WHEN** le binaire est lancé sans `--dry-run`
- **THEN** il exit non-zéro avec message clair `RECONAUT_API_KEY required (pass --dry-run to boot without a backend)`

#### Scenario: worker en --dry-run → InMemory stores, aucun appel HTTP
- **GIVEN** binaire lancé avec `--dry-run --idle-backoff=10ms`
- **WHEN** il tourne 1 seconde
- **THEN** il utilise `goodjob.NewInMemoryStore()` + `results.NewInMemoryStore()` (comportement inchangé)
- **AND** aucun appel HTTP n'est tenté (`net.Dial` mocké, compteur à 0)
