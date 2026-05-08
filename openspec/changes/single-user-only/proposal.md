# Change : single-user-only

## Pourquoi

La spec `platform` actuelle prévoit cinq rôles RBAC (`owner`, `admin`, `analyst`, `viewer`, `mcp_client`) avec un mapping vers des scopes MCP, plus l'auth locale et OIDC en parallèle. Cette complexité est cohérente quand plusieurs humains partagent une instance, mais elle ne l'est plus dans le modèle réel d'usage de Reconaut :

- L'utilisateur acte que l'application est **mono-user**. Une instance Reconaut = **un opérateur humain**, point. Pas de multi-user, pas de partage de l'instance, pas d'analyste invité avec rôle dégradé. Si plusieurs humains veulent utiliser Reconaut, ils déploient plusieurs instances (cohérent avec le modèle tenant unique déjà acté).
- Conséquences directes :
  - Pas besoin du système de rôles. Le seul user **est** owner par construction.
  - Pas besoin d'OIDC. Un IdP externe n'a pas de sens quand il n'y a qu'un compte local.
  - Pas besoin des outils MCP `list_users`, `grant_role`, `revoke_role`. Ils n'ont pas d'objet.
  - Les contrôles RBAC `caller_role:` qui parsemnent les use cases peuvent être simplifiés ou retirés.
- **Les clés API restent multiples et scopées**. Un opérateur peut générer plusieurs clés API (par ex. une pour la TUI, une pour un agent IA externe à scope réduit) et chaque clé porte son propre set de scopes. Le scoping par clé est conservé comme défense-en-profondeur, ce qui garde la matrice des scopes MCP intacte côté outils.

Ce change retire la couche multi-user / multi-rôle, simplifie le modèle d'auth à « un mot de passe + N clés API scopées appartenant au seul opérateur », et nettoie les outils / spécifications associées.

## Ce qui change

1. **Modèle de données auth simplifié**.
   - Une seule entrée `User` (ou même : pas de table user du tout, juste un `Settings` qui stocke le `password_hash` de l'opérateur unique).
   - La structure `User` perd le champ `role` ; le seul user est implicitement « l'opérateur ».
   - Les `ApiKey` n'ont plus de `user_id` (puisqu'il n'y en a qu'un) — elles ont juste un `id`, un `prefix`, un `token_hash`, des `scopes`, des timestamps.

2. **Suppression du système de rôles**.
   - `RoleResolver` est retiré ou réduit à une constante `OPERATOR_SCOPES` (l'union de tous les scopes possibles, attribuée au seul opérateur).
   - Les use cases (`Scopes::UseCases::Add`/`Revoke`/`List`, `Agent::HandleQuery`) ne reçoivent plus `caller_role:` ; le contrôle d'accès se fait au niveau **scope MCP** ou **présence d'une clé API valide** pour les endpoints REST d'auth bootstrap.
   - Les constantes `READ_ROLES`/`WRITE_ROLES`/`AUTHORIZED_ROLES`/`VALID_ROLES` sont supprimées.

3. **Suppression d'OIDC**.
   - Plus de support OIDC en v1. La spec `platform` retire les exigences relatives à un IdP externe, ainsi que les scénarios « OIDC activé en parallèle » et « Panne de l'IdP externe ne bloque pas l'instance » (devenus sans objet).

4. **Suppression des outils MCP `list_users`, `grant_role`, `revoke_role`**.
   - `list_users` n'a plus de sens. À la limite on peut le remplacer par un `whoami` qui renvoie l'identité de l'opérateur unique, mais ce n'est pas le focus du change.
   - `grant_role` / `revoke_role` n'existent pas (ils étaient mentionnés dans la matrice de `mcp-as-primary-entrypoint` mais pas encore implémentés — on les retire de la spec).
   - `list_api_keys` et `revoke_api_key` restent, simplifiés (pas de `user_id` dans les paramètres).

5. **Bootstrap simplifié**.
   - `rails reconaut:bootstrap_owner` devient `rails reconaut:bootstrap_operator` ou simplement `rails reconaut:set_password`. Il prend uniquement une variable d'env `RECONAUT_OPERATOR_PASSWORD` (plus de `_EMAIL` puisqu'il n'y a qu'un opérateur).
   - Idempotence : le bootstrap initial pose le password ; un second appel sans flag `--rotate` est rejeté.

6. **Mise à jour des changes en aval**.
   - `init-reconaut-platform/specs/platform/spec.md` : MODIFIED `Authentication and RBAC` → `Authentication (Single Operator)`.
   - `mcp-as-primary-entrypoint/specs/mcp-server/spec.md` : MODIFIED `MCP Tool Surface` (retrait des tools admin user/role) ; MODIFIED `MCP Authorization and Scopes` (matrice purgée des colonnes role).
   - `replace-web-with-tui/specs/platform/spec.md` : MODIFIED scénarios pour refléter la connexion mono-user.

## Contraintes

- **Un seul opérateur par instance, point**. Pas de mécanisme prévu pour ajouter un second user ; toute extension future se fait par un nouveau change explicite.
- **Plusieurs clés API restent autorisées** pour le seul opérateur, chacune avec son set de scopes. La défense-en-profondeur par scoping de clé est conservée.
- **Auth bootstrap = password local uniquement**. Pas de fallback OIDC. Si l'opérateur perd son password, il doit accéder au filesystem de l'instance pour exécuter `rails reconaut:reset_password`.
- **Pas de régression sur le canal MCP comme point d'entrée principal** (cf. `mcp-as-primary-entrypoint`). La simplification mono-user ne réintroduit pas des routes REST.
- **Audit conservé**. Chaque action est auditée avec le `key_id` qui l'a déclenchée. L'« acteur » dans le log d'audit devient le `key_id` de la clé API utilisée, pas l'`user_id` (puisqu'il n'y en a qu'un implicite).

## Non-objectifs (hors scope de ce change)

- **Réintroduction d'un mode multi-user**. Si la demande émerge plus tard, ce sera un change `add-multi-user-support` avec sa propre justification.
- **Réintroduction d'OIDC**. Idem, change ultérieur si nécessaire.
- **Mécanisme de partage temporaire de l'instance** (par ex. invité avec lien magique). Hors scope.
- **Outil `whoami` MCP**. Pas indispensable en mono-user ; un simple « `system_info` » qui renvoie la version pourrait être ajouté ultérieurement.
- **Suppression complète des constantes / classes liées aux rôles**. Le change pose la spec ; le cleanup code est à exécuter dans l'implémentation, qui peut conserver des ombres de classes pour la rétrocompatibilité tant que `init-reconaut-platform` n'est pas archivé.

## Décisions prises

1. **Mono-user strict.** Une instance = un opérateur. Justifié par la simplicité radicale (pas de RBAC, pas d'IdP, pas de gestion d'invitations) et par la cohérence avec le modèle tenant unique déjà acté : un MSSP qui veut servir N clients déploie N instances ; un opérateur SOC interne qui veut donner un accès limité à un collègue lui passe une clé API à scope réduit.
2. **Plusieurs clés API par opérateur, chacune scopée.** Conserve la défense-en-profondeur. La TUI prend une clé full-scope ; un agent IA externe peut prendre une clé `read:hosts` + `read:scans` seulement, etc.
3. **OIDC retiré du périmètre v1.** Justifié par le coût d'intégration OIDC vs le bénéfice nul en mono-user. Réintroductible plus tard si mode multi-user un jour.
4. **Bootstrap = `RECONAUT_OPERATOR_PASSWORD` (env), point.** Plus simple à expliquer, plus simple à auditer, pas d'email à inventer.
5. **Suppression des outils MCP `list_users`, `grant_role`, `revoke_role`.** Pas d'objet, pas d'utilisateurs à lister. `list_api_keys` et `revoke_api_key` restent, opérant sur les clés du seul opérateur.

## Différé (non bloquant, parqué pour plus tard)

- **Outil `system_info` MCP** qui renvoie version Rails, version Go, schema_versions, état de la file `good_jobs` (similaire à `system_doctor` mais sans probes booléens). À voir si utile à l'usage.
- **Rotation de password sans accès filesystem** (par ex. via une clé API scopée `write:password`). Différé : si l'opérateur perd son password, il a forcément accès au filesystem de son instance qu'il auto-héberge.
- **Cleanup code des classes role** dans le codebase Rails. À faire dans l'implémentation de ce change.
