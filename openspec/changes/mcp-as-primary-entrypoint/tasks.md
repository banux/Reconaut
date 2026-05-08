# Tâches : mcp-as-primary-entrypoint

Checklist de la bascule MCP-first : étendre la surface d'outils MCP au workflow opérateur complet, restreindre l'API REST à l'auth bootstrap + healthz + transport MCP, et faire consommer MCP à la TUI. Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Extension du périmètre des outils MCP — spec : `mcp-server`

- [x] **1.1 Catalogue de tools MCP étendu**
  - **Notes** : Étendre le registry MCP existant (`apps/api/app/lib/mcp/core_tools.rb` + `tool_registry.rb`) pour ajouter au minimum :
    - Scope : `list_scopes`, `add_scope`, `revoke_scope`
    - Scans : `list_scans` (en plus de `request_scan`/`get_scan_status` déjà livrés)
    - Agent : `agent_chat` avec streaming `tool_result` partiel via SSE
    - Admin : `list_users`, `grant_role`, `revoke_role`, `list_api_keys`, `revoke_api_key`
    - Doctor : `system_doctor` (renvoie `Reconaut::Doctor.run.to_h`)
  - Chaque outil porte un schéma de paramètres typé (JSON Schema embarqué dans le registry).
  - **Test plan** : Pour chaque nouvel outil, un spec d'intégration qui invoque l'outil via le transport HTTP+SSE in-process, assert le schéma de la réponse, assert qu'une ligne d'audit existe avec le `tool_name` correspondant. Test négatif : invoquer chaque outil sans le scope requis renvoie `unauthorized` nommant le scope manquant.

- [x] **1.2 Streaming `agent_chat` via tool_result partiels**
  - **Notes** : L'outil `agent_chat` reçoit `{ prompt, context? }`, exécute le pipeline hybride existant (`Agent::HybridRetriever`), et émet le résultat en chunks via le mécanisme `tool_result` partiel du transport MCP HTTP+SSE. Côté Rails, on s'appuie sur `ActionController::Live` + le SDK MCP pour pousser les chunks. Chaque chunk porte un fragment de réponse + ses citations `(host_id, scanned_at)`.
  - **Test plan** : Test e2e avec un client MCP de test : invoquer `agent_chat({"prompt": "modbus en France"})` ; recevoir au moins 3 chunks ; assert que la concaténation des chunks égale la réponse complète et que chaque chunk porte ses citations.

- [x] **1.3 Matrice de scopes RBAC mise à jour**
  - **Notes** : Compléter la table de scopes (cf. spec `mcp-server` modifiée) — `read:scopes`/`write:scopes` pour la gestion de scope, `read:users`/`write:users` pour l'admin, etc. Le middleware d'auth MCP charge cette matrice au boot et rejette les appels hors scope avec une erreur structurée nommant le scope manquant.
  - **Test plan** : Test paramétré qui exerce chaque combinaison (rôle, outil) et assure permis/refusé selon la matrice. Une clé `viewer` qui invoque `add_scope` reçoit `unauthorized` nommant `write:scopes`.

---

## 2. Restriction de l'API REST — spec : `mcp-server`

- [x] **2.1 Linter d'allowlist REST**
  - **Notes** : Script CI `scripts/check_rest_allowlist.sh` qui parse `apps/api/config/routes.rb` (ou le résultat de `bin/rails routes`) et vérifie que chaque route REST exposée appartient à l'allowlist : `POST /auth/sessions`, `DELETE /auth/sessions/{id}`, `POST /auth/api_keys`, `DELETE /auth/api_keys/{id}`, `GET /healthz`, `*/mcp/*`. Toute autre route fait échouer le check avec le message `rest-route-not-allowed`.
  - **Test plan** : Le script tourne sur HEAD ; il échoue actuellement parce que les controllers `ScopesController`, `Agent::ChatController` etc. déclarent des routes hors allowlist. Documenter cet état initial. Test : ajouter une nouvelle route `GET /reports` dans `routes.rb` → le linter échoue.

- [x] **2.2 Endpoint `GET /healthz` non authentifié**
  - **Notes** : Vérifier qu'il existe ; si non, l'ajouter (controller minimal, route hors auth middleware). Body `{"status":"ok"}` quand le process sert ; pas de DB query lourde.
  - **Test plan** : Spec request : `GET /healthz` sans header d'auth renvoie 200 + body `{"status":"ok"}`. Aucune ligne d'audit n'est écrite (le test compte 0 nouvelle ligne audit).

- [x] **2.3 Auth bootstrap REST stabilisé**
  - **Notes** : Confirmer le contrat des endpoints `POST /auth/sessions` et `POST /auth/api_keys`. Documenter dans `docs/architecture/auth-bootstrap.md` que ces endpoints restent REST volontairement et pourquoi (œuf et poule de la clé API).
  - **Test plan** : Specs request existants restent verts. La page de doc référence le change `mcp-as-primary-entrypoint`.

- [x] **2.4 Marquer les controllers REST hérités comme `@deprecated`**
  - **Notes** : Ajouter un commentaire `# DEPRECATED: route REST historique, à retirer dans le change remove-rest-wrappers une fois la TUI migrée sur MCP` au top de chaque controller hors allowlist (`ScopesController`, `Agent::ChatController`, `MCP::ToolsController` partie REST si applicable). N'introduire AUCUNE nouvelle action dans ces controllers.
  - **Test plan** : Test grep : tous les controllers hors allowlist portent l'annotation deprecated.

---

## 3. La TUI consomme MCP — spec : `architecture`

- [x] **3.1 Client MCP Go embarqué dans `apps/tui/`**
  - **Notes** : Implémenter ou intégrer un client MCP Go minimal (transport HTTP+SSE) sous `apps/tui/internal/mcp/`. Le client expose `Invoke(toolName, params, opts) (Result, error)` et `InvokeStreaming(toolName, params, opts) (<-chan Chunk, error)` pour `agent_chat`. Auth via header `Authorization: Bearer <api_key>`.
  - **Test plan** : Test contre un serveur HTTP+SSE de test qui simule deux outils (`echo`, `stream_echo`) ; assert que `Invoke` retourne le bon résultat et que `InvokeStreaming` émet les chunks dans l'ordre.

- [x] **3.2 Sous-commandes TUI passent par MCP**
  - **Notes** : Réécrire les sous-commandes `scope`, `scan`, `hosts`, `agent`, `doctor` (squelettes du change `replace-web-with-tui`) pour appeler les outils MCP correspondants via le client de §3.1, plutôt que des routes REST. Le binaire ne contient plus de fichier `apps/tui/internal/api/scopes.go` ou équivalent — uniquement `internal/mcp/` + des renderers TUI par outil.
  - **Test plan** : Test e2e par sous-commande : capturer l'URL appelée, vérifier qu'elle est sous `/mcp/*` (sauf `login` qui appelle `/auth/sessions` puis `/auth/api_keys`).

- [x] **3.3 Linter sur les chemins HTTP appelés par la TUI**
  - **Notes** : Script CI `scripts/check_tui_mcp_only.sh` qui parse les chaînes littérales d'URL dans `apps/tui/` et vérifie que toutes commencent par `/mcp/`, `/auth/sessions`, `/auth/api_keys` ou `/healthz`. Toute autre URL fait échouer.
  - **Test plan** : Le linter passe sur HEAD après §3.2. Test : ajouter `client.Get("/scopes")` dans `apps/tui/cmd/reconautctl/scope.go` → linter échoue.

---

## 4. Mise à jour des changes connexes

- [x] **4.1 Mettre à jour `replace-web-with-tui`**
  - **Notes** : Le change `replace-web-with-tui` mentionnait que la TUI parle un client REST maison ; ajouter une note dans son `proposal.md` indiquant que la couche `internal/api/` est remplacée par `internal/mcp/` au moment où `mcp-as-primary-entrypoint` est implémenté. Pas de changement de spec, juste un alignement des notes.
  - **Test plan** : `grep -i "internal/api" openspec/changes/replace-web-with-tui/` ne renvoie plus de référence active après mise à jour.

- [x] **4.2 Mettre à jour `openspec/project.md`**
  - **Notes** : Section *Stack* / *Différenciateurs* : repositionner « Serveur MCP » comme **point d'entrée principal** plutôt que comme une fonctionnalité secondaire pour les agents IA. Indiquer explicitement que la TUI consomme MCP.
  - **Test plan** : `grep -i "mcp.*principal\|primary entry" openspec/project.md` renvoie ≥ 1 match.

- [x] **4.3 Documenter la migration des controllers REST hérités**
  - **Notes** : Page `docs/architecture/mcp-first.md` qui explique : pourquoi MCP est canal principal, quels controllers REST restent (auth bootstrap + healthz + MCP transport), comment porter une feature existante en outil MCP, et quand le change `remove-rest-wrappers` retirera les wrappers.
  - **Test plan** : La page existe et est référencée depuis `README.md` et `docs/architecture/scan-frontier.md`.

---

## 5. Acceptance pour le change dans son ensemble

- [x] **5.1 Tests automatisés pour chaque outil MCP étendu**
  - Chaque outil ajouté en §1 a au moins (a) un spec happy path, (b) un spec d'autorisation (rôle insuffisant → `unauthorized`), (c) un spec d'audit (ligne écrite avec `tool_name`).

- [x] **5.2 Linter d'allowlist REST actif en CI**
  - `scripts/check_rest_allowlist.sh` tourne sur chaque PR. La fusion d'une nouvelle route hors allowlist est bloquée.

- [x] **5.3 Linter MCP-only TUI actif en CI**
  - `scripts/check_tui_mcp_only.sh` tourne sur chaque PR. La fusion d'un appel HTTP hors `/mcp/*` ou `/auth/*`/`/healthz` est bloquée.

- [x] **5.4 Test e2e du parcours TUI complet via MCP**
  - Démarrer un Rails de test (in-process), créer un compte owner, lancer `reconautctl login` (REST), puis enchaîner `scope add` / `scan request` / `agent` / `doctor` (tous via MCP). Capturer l'audit log : il y a une ligne par invocation MCP, plus deux lignes pour l'auth bootstrap.

- [x] **5.5 Une seule clé API sert TUI et un agent IA**
  - Test e2e : générer une clé via la TUI ; utiliser la même clé depuis un client MCP Python/Node de test pour invoquer `request_scan` ; assurer que les deux usages réussissent et que la révocation côté MCP coupe les deux dans la minute.
