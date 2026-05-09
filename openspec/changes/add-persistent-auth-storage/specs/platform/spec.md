# Spec delta : platform

## MODIFIED Requirements

### Requirement: Authentication (Single Operator)
Reconaut est livré en mode **mono-user** en v1. Une instance = **un seul opérateur humain**, identifié par un mot de passe local hashé Argon2id. Aucune notion de rôle, aucun second compte, aucun mécanisme d'invitation. L'authentification DOIT se faire **localement** — pas de support OIDC ou autre IdP externe en v1.

L'opérateur DOIT pouvoir générer **plusieurs clés API** rattachées à son compte unique, chacune portant son propre set de scopes MCP. La révocation d'une clé n'affecte pas les autres.

**Persistance.** Reconaut DOIT persister l'opérateur unique et ses clés API en base Postgres via ActiveRecord, de telle sorte que :

- la rake task `reconaut:set_password` (process Ruby distinct) et le serveur Rails (autre process) partagent **la même source de vérité** ;
- un redémarrage du serveur Rails ne perd ni le user ni ses clés API actives ;
- un test unitaire de `Authenticator` continue de pouvoir injecter un store in-memory pour la rapidité (les adapters in-memory restent utilisables comme backend de test).

#### Scenario: Cycle bootstrap → login depuis un autre process
- **GIVEN** un Postgres frais et une instance Rails fraîchement bootée (aucun user en base)
- **WHEN** l'opérateur exécute `RECONAUT_OPERATOR_PASSWORD=… bundle exec rails reconaut:set_password`
- **AND** dans un terminal séparé, sur le même Postgres, lance `reconautctl login --password …`
- **THEN** la requête `POST /auth/sessions` retourne **201 Created** avec un `api_key.token`
- **AND** la table `users` contient exactement une ligne avec l'email opérateur et un `password_hash` Argon2id
- **AND** la table `api_keys` contient au moins une ligne rattachée à ce user, avec `token_hash` (SHA-256), `prefix`, et `scopes` populés

#### Scenario: Persistance après redémarrage du serveur Rails
- **GIVEN** un user opérateur déjà bootstrappé en base et une clé API valide
- **WHEN** le serveur Rails est redémarré (process killed et relancé)
- **THEN** la requête `GET /mcp/tools/list_scopes` avec `Authorization: Bearer <token>` retourne **200**
- **AND** aucune entrée n'a été perdue : `api_keys.count` est inchangé

#### Scenario: Rotation du password via la rake task
- **GIVEN** un user opérateur existant avec deux clés API actives (`k1`, `k2`)
- **WHEN** l'opérateur exécute `RECONAUT_ROTATE=true RECONAUT_OPERATOR_PASSWORD=newpwd bundle exec rails reconaut:set_password`
- **THEN** la rake task imprime `rotated: true` et un nouveau `api_key`
- **AND** en base, `users.password_hash` reflète le hash du nouveau password (l'ancien hash n'est plus présent)
- **AND** les clés API `k1` et `k2` ont leur `revoked_at` posé à `now()` (révocation en masse)
- **AND** une requête `Authorization: Bearer <token de k1>` retourne **401**

#### Scenario: Refus de la création d'un second user (mode mono-user)
- **GIVEN** une instance avec un user opérateur déjà créé
- **WHEN** un appelant tente `Reconaut::Auth::Bootstrap.call(email: "alice@local", password: "x", rotate: false)`
- **THEN** l'appel lève `Reconaut::Auth::Bootstrap::AlreadyInitializedError`
- **AND** la table `users` contient toujours exactement **une** ligne (pas de second user inséré)

#### Scenario: Token jamais persisté en clair
- **GIVEN** une clé API fraîchement créée via `Authenticator#issue_api_key`
- **WHEN** on inspecte la ligne correspondante dans `api_keys`
- **THEN** la colonne `token_hash` contient un hex de 64 caractères (SHA-256), **pas** la valeur brute
- **AND** aucune colonne ne contient le token en clair (vérifié par grep sur le schéma : `\d api_keys` n'expose aucune colonne `token` plain)

#### Scenario: Aucune colonne tenant_id dans la migration
- **GIVEN** la migration `create_auth_tables`
- **WHEN** `bin/rails db:migrate` est exécutée
- **THEN** ni `users` ni `api_keys` ne portent de colonne `tenant_id`
- **AND** le linter `scripts/check_stack.sh` reste vert

## ADDED Requirements

### Requirement: Backend de stockage auth interchangeable
La couche `Reconaut::Auth::Authenticator` DOIT rester agnostique au backend de stockage. L'interface publique des stores DOIT être identique entre l'implémentation in-memory (utilisée par les tests rapides) et l'implémentation ActiveRecord (utilisée en prod et dans les specs d'intégration).

L'interface DOIT comporter au minimum :

- `Users#create(email:, password_hash:)` → `User`
- `Users#find_by_email(email)` → `User | nil`
- `Users#find(id)` → `User | nil`
- `Users#list` → `Array<User>`
- `Users#set_password_hash!(id, hash)` → `User | nil`
- `Users#disable!(id)` → `User | nil`
- `ApiKeys#create_for(user_id:, scopes:)` → `[ApiKey, raw_token]`
- `ApiKeys#find_by_token(raw)` → `ApiKey | nil`
- `ApiKeys#list` (et `list_for(user_id)` en alias) → `Array<ApiKey>`
- `ApiKeys#revoke!(id)` → `ApiKey | nil`
- `ApiKeys#revoke_all!` → `nil`

`Reconaut::Registry.default` DOIT choisir automatiquement l'implémentation : ActiveRecord si la connexion est établie ET la table `users` existe, in-memory sinon.

#### Scenario: Le même set d'examples passe contre les deux backends
- **GIVEN** un module `SharedExamples::AuthStorage` qui contient les assertions communes
- **WHEN** `rspec spec/lib/reconaut/auth/storage_spec.rb` (in-memory) est lancé
- **AND** `rspec spec/lib/reconaut/auth/storage_active_record_spec.rb` est lancé
- **THEN** les deux fichiers passent avec **les mêmes** assertions, sans duplication de code

#### Scenario: Switch automatique en l'absence de DB
- **GIVEN** un test unitaire qui n'a pas de connexion Postgres établie
- **WHEN** le test instancie `Reconaut::Registry.new`
- **THEN** le Registry retourne des `Storage::InMemoryUsers` et `Storage::InMemoryApiKeys`
- **AND** aucun appel à `ActiveRecord::Base.connection` n'est tenté
