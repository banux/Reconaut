# Tâches : single-user-only

Checklist du passage en mode mono-user. Suppression du système de rôles, suppression d'OIDC, simplification du bootstrap, retrait des outils MCP `list_users`/`grant_role`/`revoke_role`. Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Modèle de données auth simplifié

- [x] **1.1 `User` perd le champ `role`**
  - **Notes** : Modifier `Reconaut::Auth::User` pour retirer le champ `role` (ou le maintenir avec une valeur figée `:operator` si le retrait casse trop de tests existants — décision à acter à l'implémentation). Mettre à jour `InMemoryUsers#create` pour ne plus accepter `role:`.
  - **Test plan** : `spec/lib/reconaut/auth/storage_spec.rb` adapté ; les tests vérifient qu'un user créé n'a pas de notion de rôle. `User#to_h` ne renvoie plus de clé `:role`.

- [x] **1.2 `ApiKey` indépendant de `user_id`**
  - **Notes** : Le champ `user_id` peut disparaître ou être figé à une constante `OPERATOR_ID = "operator"`. Les méthodes `list_for(user_id)` deviennent `list` (zéro paramètre).
  - **Test plan** : `spec/lib/reconaut/auth/storage_spec.rb` confirme `InMemoryApiKeys#list` renvoie toutes les clés ; `find_by_token` continue de marcher.

- [x] **1.3 Constante `VALID_ROLES` retirée**
  - **Notes** : Supprimer `Reconaut::Auth::VALID_ROLES`. Si du code (use cases, controllers) l'importe, le simplifier en parallèle (cf. §2).
  - **Test plan** : `grep -rn "VALID_ROLES" apps/api/` ne renvoie plus rien.

---

## 2. Suppression du système de rôles

- [x] **2.1 Retirer `RoleResolver`**
  - **Notes** : Supprimer `apps/api/app/controllers/concerns/role_resolver.rb` et toutes ses inclusions. Les controllers qui l'utilisaient (`ScopesController`, `Agent::ChatController`, `MCP::ToolsController`) sont déjà dépréciés au profit de MCP, donc on peut soit les supprimer (mieux), soit les simplifier pour accepter directement les scopes de la clé API courante.
  - **Test plan** : `grep -rn "RoleResolver\|caller_role" apps/api/` ne renvoie plus rien après cleanup.

- [x] **2.2 Use cases sans `caller_role:`**
  - **Notes** : Modifier `Scopes::UseCases::Add`/`Revoke`/`List`, `Agent::HandleQuery` pour retirer le paramètre `caller_role:`. Le contrôle d'accès se fait au niveau MCP scope (déjà en place dans `Mcp::Tool#call`) ou au niveau auth bootstrap (présence d'une clé API valide).
  - **Test plan** : Les specs de use cases adaptés ; chaque use case prend `caller_id:` mais plus `caller_role:`. Aucune réponse `:unauthorized` retournée par le use case (le contrôle vit ailleurs).

- [x] **2.3 Constantes `READ_ROLES` / `WRITE_ROLES` / `AUTHORIZED_ROLES` retirées**
  - **Notes** : Supprimer les constantes ; les use cases ne checkent plus de rôles.
  - **Test plan** : `grep -rn "READ_ROLES\|WRITE_ROLES\|AUTHORIZED_ROLES" apps/api/` ne renvoie plus rien.

- [x] **2.4 `MCP::ToolsController::SCOPES_BY_ROLE` retirée**
  - **Notes** : La table de mapping role→scopes dans le controller MCP n'a plus de sens. Le controller doit lire les scopes directement de la clé API authentifiée (champ `scopes` sur `ApiKey`). Si cette information n'est pas encore portée par `ApiKey`, l'ajouter dans une migration mineure (champ `scopes:string[]` ou `scopes:jsonb`).
  - **Test plan** : Specs request MCP : une clé créée avec scopes `["read:hosts"]` invoque `search_hosts` avec succès et `add_scope` avec `unauthorized`. La table `SCOPES_BY_ROLE` n'est plus référencée nulle part.

---

## 3. Suppression d'OIDC

- [x] **3.1 Retirer toute référence OIDC**
  - **Notes** : Si le code embarque une gem OIDC (`omniauth-oidc`, `openid_connect`), la retirer du Gemfile. Si des controllers OIDC existent, les supprimer. Documenter dans le `CHANGELOG.md` (s'il existe) que OIDC n'est pas livré.
  - **Test plan** : `grep -rniE "oidc|openid_connect|omniauth" apps/api/Gemfile apps/api/app/` ne renvoie aucune occurrence active.

---

## 4. Bootstrap simplifié

- [x] **4.1 Renommer `bootstrap_owner` → `set_password`**
  - **Notes** : Mettre à jour `lib/tasks/reconaut.rake`. La nouvelle task lit `RECONAUT_OPERATOR_PASSWORD` (et c'est tout — pas d'email). Idempotence : refuse si un password existe déjà sauf flag `--rotate` (qui rote le password en révoquant les clés API existantes pour les forcer à se réauthentifier).
  - **Test plan** : Test rake : `RECONAUT_OPERATOR_PASSWORD=hunter2 rake reconaut:set_password` réussit la première fois, échoue la seconde (sans `--rotate`), réussit la seconde avec `--rotate` et révoque les clés API existantes.

- [x] **4.2 Endpoint `POST /auth/sessions` accepte juste `password`**
  - **Notes** : Plus d'email dans le body de login. Body : `{"password": "..."}` → renvoie une session/clé API.
  - **Test plan** : Spec request : login avec mauvais password renvoie 401 ; login avec password correct renvoie une clé API. Email dans le body est ignoré ou rejeté par le validateur de schéma.

---

## 5. Outils MCP nettoyés

- [x] **5.1 Retirer `list_users` du registry**
  - **Notes** : Supprimer le bloc `list_users` ajouté dans `Mcp::CoreTools.register_all!`. Supprimer le spec `spec/lib/mcp/admin_tools_spec.rb` parties `list_users`. Mettre à jour le test request `spec/requests/mcp/tools_spec.rb` qui asserte la liste exposée.
  - **Test plan** : `bundle exec rspec spec/lib/mcp/admin_tools_spec.rb` passe ; `Mcp::ToolRegistry.names` ne contient pas `list_users`.

- [x] **5.2 `list_api_keys` perd le paramètre `user_id`**
  - **Notes** : Le tool prend `params_schema: {}` (aucun paramètre). Le handler renvoie toutes les clés via `api_key_storage.list`.
  - **Test plan** : Spec adapté ; un appel avec `params: { user_id: "x" }` est rejeté par le validateur (paramètre inconnu) ou ignoré.

- [x] **5.3 Anticiper `grant_role`/`revoke_role` non implémentés**
  - **Notes** : Vérifier qu'aucun code ne référence ces noms — ils n'avaient pas encore été implémentés mais seraient apparus dans la matrice de scopes. Confirmer leur absence dans la doc / les commentaires.
  - **Test plan** : `grep -rn "grant_role\|revoke_role" apps/api/` ne renvoie rien.

---

## 6. Mise à jour des changes en aval

- [x] **6.1 Mettre à jour `init-reconaut-platform/specs/platform/spec.md`**
  - **Notes** : Le change `single-user-only` REMOVE l'ancienne `Authentication and RBAC` et ADD `Authentication (Single Operator)`. À l'archivage, la version finale dans `openspec/specs/platform/spec.md` sera la nouvelle.
  - **Test plan** : `openspec validate single-user-only` (CLI ad hoc, ou linter Markdown) confirme la cohérence des MODIFIED/REMOVED.

- [x] **6.2 Mettre à jour `mcp-as-primary-entrypoint/specs/mcp-server/spec.md`**
  - **Notes** : Le change `single-user-only` MODIFIE la matrice de scopes pour retirer la colonne « Rôle minimum ». À l'archivage du change parent, c'est la matrice purgée qui s'applique.
  - **Test plan** : Pas de matrice avec colonne « Rôle » dans le spec final ; la doc reste cohérente.

- [x] **6.3 Mettre à jour `replace-web-with-tui/specs/platform/spec.md`**
  - **Notes** : Les scénarios « Viewer tente de déclencher un scan via la TUI » deviennent caducs. Reformuler en : « clé API à scope insuffisant tente une action mutante ».
  - **Test plan** : `grep -i "viewer\|owner\|admin\|analyst" openspec/changes/replace-web-with-tui/specs/platform/spec.md` ne renvoie plus de référence aux rôles.

- [x] **6.4 Mettre à jour `openspec/project.md`**
  - **Notes** : La section *Stack* mentionne « auth locale + OIDC » et « cinq rôles ». Réécrire en « auth mono-user (un opérateur, password local + N clés API scopées) ».
  - **Test plan** : `grep -niE "OIDC|owner.*admin.*analyst" openspec/project.md` ne renvoie plus de référence.

---

## 7. Acceptance pour le change dans son ensemble

- [x] **7.1 Tests automatisés alignés sur le mono-user**
  - Aucun spec ne référence `caller_role`, `VALID_ROLES`, `READ_ROLES`, `WRITE_ROLES`, `RoleResolver`. Tous les chemins de contrôle d'accès passent par les scopes MCP.

- [x] **7.2 Linter de stack étendu**
  - `scripts/check_stack.sh` rejette toute introduction d'un nouveau rôle ou d'une dépendance OIDC. Test : ajouter `gem "omniauth-oidc"` dans le Gemfile → linter échoue.

- [x] **7.3 E2e mono-user**
  - Test e2e : `set_password` puis `login` avec password → clé full-scope → invoque trois outils MCP → success. Tenter d'appeler un endpoint multi-user (création d'un second user, par ex.) → 404 ou 400.

- [x] **7.4 La routine `doctor` reflète l'absence de RBAC multi-rôle**
  - `Reconaut::Doctor` ne contient plus de check `rbac_matrix` ; le rapport n'évoque pas de rôles.
