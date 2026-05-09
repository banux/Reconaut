# Change : add-persistent-auth-storage

## Pourquoi

Le store des `users` et `api_keys` est aujourd'hui en mémoire vive (`Reconaut::Auth::Storage::InMemoryUsers` / `InMemoryApiKeys`). Conséquence directe et observée en local : la rake task `reconaut:set_password` crée un opérateur dans son propre process Ruby, l'imprime, puis termine — le serveur Rails (autre process) garde son `Registry.default` vierge. Quand `reconautctl login` tape `POST /auth/sessions`, il y a zéro user → 401 `invalid_credentials`.

Le commentaire en tête de `Storage` documente déjà cette limitation :

> Stockage en memoire (tests + dev local). DB-backed via ActiveRecord quand le modele User sera cree par init-reconaut-platform.

Il s'agit d'un dette identifiée par `init-reconaut-platform` §7.1 ("Authentification local-first, OIDC optionnel"). On la livre dans un change dédié plutôt que de la fondre dans le mégaformat init, pour rester focalisé.

Ce change rend les `users` et `api_keys` **persistants en Postgres** via ActiveRecord, en respectant le mode mono-user (cf. `single-user-only`) :

- une seule entrée `users` peut exister à un instant T (contrainte applicative + index unique sur `email` + helper `solo_user!`) ;
- les `api_keys` sont rattachées à cet unique opérateur via `user_id`, mais leur scope par clé reste pleinement supporté ;
- aucun rôle, aucune table de tenants, aucun champ `tenant_id` (cf. `check_stack.sh` qui rejette `tenant_id` dans les migrations).

Les `Storage::InMemory*` deviennent les backends utilisés **par les tests unitaires** uniquement ; la prod pointe vers `Storage::ActiveRecord*`. Le constructeur de `Authenticator` et de `Bootstrap` reste agnostique à l'implémentation grâce à l'interface déjà existante (`create`, `find_by_email`, `list`, `set_password_hash!`, `disable!`, `create_for`, `find_by_token`, `list`, `revoke!`, `revoke_all!`).

## Ce qui change

1. **Migration Rails `create_auth_tables`** : crée `users` et `api_keys`.
   - `users(id uuid pk, email citext unique, password_hash text not null, created_at, disabled_at)` — `citext` pour rendre l'email case-insensitive sans convertir manuellement.
   - `api_keys(id uuid pk, user_id uuid fk users.id on delete cascade, prefix varchar(8), token_hash varchar(64), scopes text[] not null, created_at, revoked_at)` — index unique sur `token_hash`, index sur `user_id`.
   - Pas de colonne `tenant_id` (invariant `check_stack.sh`).

2. **Modèles ActiveRecord** : `Auth::User` et `Auth::ApiKey` minimalistes, sans logique métier — la logique reste dans `Reconaut::Auth::Authenticator`. Les modèles AR servent juste de mapping table ↔ Struct existant.

3. **Adapters `Storage::ActiveRecordUsers` et `Storage::ActiveRecordApiKeys`** : implémentent la même interface publique que les `InMemory*`. Tests parallèles : la suite `storage_spec.rb` actuelle tourne contre l'adapter AR avec un `before(:each)` qui truncate les tables.

4. **`Registry.default` choisit le backend** :
   - Si `ActiveRecord::Base.connected?` ET la table `users` existe → adapters AR.
   - Sinon → `InMemory*` (fallback dev minimal, conserve le comportement actuel pour les tests qui n'utilisent pas la DB).

5. **`reconaut:set_password` persiste réellement** : la rake task hérite du switch automatique du Registry. Elle inscrit le user et l'api_key dans Postgres ; le serveur Rails (autre process) lit la même table → login fonctionne.

6. **Spec `platform` modifiée** : Requirement `Authentication (Single Operator)` enrichi d'une obligation de persistance (`Reconaut DOIT persister l'opérateur unique et ses clés API en base, de telle sorte que la rake task de bootstrap et le serveur HTTP partagent la même source de vérité`).

## Contraintes

- **Mode mono-user inchangé**. La table `users` admet **une seule** ligne en pratique. La contrainte est applicative (`Bootstrap.call` refuse si `users.count > 0` sauf `rotate: true`) et défensive (helper `Authenticator#from_password_only` rejette si > 1 user). On n'ajoute **pas** de check constraint Postgres `(SELECT COUNT(*) FROM users) <= 1` (couplage rigide qui interagit mal avec les migrations).
- **Pas de cascade RGPD**. La table `users` ne contient ni nom, ni adresse, ni téléphone, ni IP — uniquement `email` (matricule local par défaut `operator@local`) et `password_hash`. La page `responsibility-model.md` est cohérente : "Reconaut ne stocke pas de PII".
- **Hash Argon2id intact**. Aucun changement sur `PasswordHasher` ; on persiste juste le hash déjà calculé.
- **Tokens jamais persistés en clair**. Seul le `token_hash` (SHA-256) est stocké, identique au comportement actuel de `InMemoryApiKeys`. Le linter `check_stack.sh` n'a pas besoin d'évoluer.
- **Compatible avec `single-user-only` matrice de scopes**. Les `scopes` sont un `text[]` Postgres — la lecture renvoie un Array, l'écriture accepte un Array. Pas de table de jointure (`api_key_scopes`) — overkill pour ~10 valeurs énumérées.
- **Tests unitaires sans DB conservés**. `spec/lib/reconaut/auth/storage_spec.rb` tourne actuellement contre `InMemoryUsers/InMemoryApiKeys` ; on ajoute un fichier parallèle `storage_active_record_spec.rb` qui tourne contre l'adapter AR. Les deux fichiers partagent le même set d'assertions via un module `SharedExamples::AuthStorage`.
- **Schema migration via `bin/rails db:migrate`**. Aucun seeding implicite — c'est `reconaut:set_password` qui crée le user.
- **Pas de cache de login**. `from_password_only` continue de tourner contre la DB à chaque requête. Argon2id est lent par construction (~300 ms) ; un cache de session côté Rails serait utile mais relève d'un autre change (`add-session-cache`).

## Non-objectifs (hors scope de ce change)

- **OIDC / IdP externe** — relève de `init-reconaut-platform` §7.2, hors scope.
- **Rate limiting du login** — relève d'un futur `add-auth-throttling`.
- **Cache de session** — `from_password_only` reste idempotent ; un cache vivra dans `add-session-cache`.
- **Audit log d'auth** — la table `audit_log` existante (cf. `init-reconaut-platform` §1.4) capture déjà les événements applicatifs ; ce change ne lui ajoute pas d'événements supplémentaires.
- **Migration des données in-memory existantes** — il n'y a pas de "données existantes" en in-memory à migrer (chaque process repart à zéro). On bascule simplement le backend.
- **Multi-tenant** — impossible par construction (linter `check_stack.sh` rejette `tenant_id`).
- **Renommage de `email` en `username`** — l'email reste le matricule par cohérence avec la rake task et l'historique. Un opérateur peut mettre `operator@local` (défaut), `bastien@reconaut.local`, peu importe — c'est un identifiant local, pas une adresse réelle.

## Décisions prises

1. **`citext` plutôt que `text` + lower()**. `citext` rend l'unicité de l'email naturellement case-insensitive — moins de frottement que d'imposer un downcase systématique côté Ruby. Compatible avec `Bootstrap.call` qui downcase déjà avant comparaison ; pas de régression.
2. **`scopes` comme `text[]`**. ~10 valeurs énumérées, peu d'écritures, pas de besoin de FK vers une table `permissions`. Une table de jointure complexifierait sans bénéfice — la matrice de validation des scopes vit dans `Reconaut::Mcp::ScopeMap` (cf. `single-user-only`) qui filtre déjà à l'usage.
3. **Pas de soft-delete pour `api_keys`**. On a déjà `revoked_at` qui joue ce rôle et préserve la trace (cohérent avec `scan_scope_entries.revoked_at` côté scanning). Une clé révoquée reste dans la table pour l'audit.
4. **Switch in-memory ↔ AR via détection runtime** plutôt que via une env var. Évite un nouveau levier de config ; le code se comporte automatiquement bien selon que la migration est jouée ou pas. Les tests qui veulent forcer l'in-memory passent leur store directement à `Authenticator.new(users: ..., api_keys: ...)`.
5. **Pas de `lockable` style Devise**. Reconaut est mono-user — il n'y a personne pour t'invalider ton compte. La protection contre le bruteforce relèvera de `add-auth-throttling`.

## Différé (non bloquant, parqué pour plus tard)

- **Cache de session** (`add-session-cache`) : éviter de hasher Argon2id à chaque requête authentifiée par password (les requêtes API key tapent juste un `find_by_token` qui est ~µs en index hash).
- **Throttling** (`add-auth-throttling`) : limiter les tentatives de login par IP source / clé API. Important si l'instance est exposée sur internet — différé tant que le déploiement nominal reste local-network.
- **Rotation programmée des clés API** : aujourd'hui la rotation est manuelle (`reconaut:set_password --rotate`). Un futur `add-key-rotation` ajoutera une expiration optionnelle (`expires_at`) + un job de notification.
- **Backup des `users` / `api_keys`** : relève de la stratégie de backup Postgres globale, qui sera tracée par un futur `add-backup-strategy`.
