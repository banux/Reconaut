# MCP-first — pourquoi MCP est le canal d'entrée principal

Statut : **acté** par le change [`mcp-as-primary-entrypoint`](../../openspec/changes/mcp-as-primary-entrypoint/proposal.md).
Audience : contributeurs et opérateurs qui veulent ajouter une feature opérateur ou comprendre la trajectoire de migration.

## TL;DR

- Le serveur **MCP HTTP+SSE** intégré au process Rails est le **canal opérateur primaire**.
- L'API REST est restreinte à trois familles : **auth bootstrap**, **healthcheck**, **transport MCP**. Tout le reste passe par un outil MCP.
- La TUI `reconautctl` parle MCP pour les opérations métier ; les agents IA externes parlent MCP ; les scripts CI parlent MCP. Tous avec la même clé API personnelle.
- Un linter CI bloque l'introduction d'une nouvelle route REST hors allowlist.
- Un second linter CI bloque l'introduction d'une URL non-MCP dans le binaire `reconautctl`.

## Pourquoi MCP plutôt qu'une API REST « normale »

Avant ce change, Rails exposait deux surfaces parallèles :

1. **Une API REST** historique (`POST /agent/chat`, `resources :scopes`, …) consommée par la SPA Vue puis, après [`replace-web-with-tui`](../../openspec/changes/replace-web-with-tui/), par le binaire `reconautctl`.
2. **Un serveur MCP** sous `/mcp/*` consommé par les agents IA externes.

Cette duplication est coûteuse :

- **Double surface d'authentification, audit et rate-limit** à durcir (les middlewares finissent par diverger).
- **Double surface de schéma** : chaque feature doit être déclarée comme controller REST + outil MCP avec des contrats différents (JSON pur vs `tool_result` MCP).
- **Double point de friction pour les agents IA** qui veulent automatiser : l'API REST n'est jamais aussi bien instrumentée que MCP côté tooling.

Le change [`mcp-as-primary-entrypoint`](../../openspec/changes/mcp-as-primary-entrypoint/) acte qu'on **collapse les deux surfaces sur MCP** :

- Une seule clé API personnelle par opérateur, valable pour TUI ET agents IA (cf. spec [`platform`](../../openspec/changes/mcp-as-primary-entrypoint/specs/platform/spec.md)).
- Un seul middleware d'auth, un seul middleware d'audit, un seul rate-limit.
- Un seul format de réponse (`tool_result` MCP).

## Quels controllers REST restent

Cf. [`auth-bootstrap.md`](./auth-bootstrap.md) pour le détail. En résumé :

| Famille          | Routes                                                                | Statut                                                                          |
|------------------|-----------------------------------------------------------------------|----------------------------------------------------------------------------------|
| Auth bootstrap   | `POST /auth/sessions`, `POST /auth/api_keys`, `DELETE /auth/api_keys/:id` | **Stable, REST volontairement** (œuf et poule de la clé API).                   |
| Healthcheck      | `GET /healthz`                                                        | **Stable** — probe non authentifié pour LB / k8s / blackbox prometheus.          |
| Transport MCP    | `/mcp/tools`, `/mcp/tools/:tool_name`                                 | **Stable** — c'est le transport MCP HTTP+SSE.                                    |
| Tout le reste    | `resources :scopes`, `POST /agent/chat`                               | **DEPRECATED** — annoté en haut du controller, sera retiré par `remove-rest-wrappers`. |

Le linter [`scripts/check_rest_allowlist.sh`](../../scripts/check_rest_allowlist.sh) tourne en CI et rejette toute nouvelle route hors de l'allowlist.

## Comment porter une feature existante en outil MCP

Procédure type pour migrer un controller REST vers un outil MCP :

1. **Identifier la capacité métier**. Exemple : `POST /agent/chat` → tool `agent_chat`.
2. **Définir le schéma de paramètres typé**. Le registre MCP utilise un mini-langage (`type: :string|:integer|:enum|:hash`, `min_length`, `max_length`, `min`, `max`, `required`, `default`). Cf. [`apps/api/app/lib/mcp/tool_registry.rb`](../../apps/api/app/lib/mcp/tool_registry.rb).
3. **Choisir le scope RBAC** dans la matrice (cf. spec [`mcp-server`](../../openspec/changes/single-user-only/specs/mcp-server/spec.md) après `single-user-only`). Exemples : `read:hosts`, `write:scans`, `agent:chat`, `read:health`, `write:api_keys`.
4. **Enregistrer l'outil** dans `Mcp::CoreTools.register_all!` ([apps/api/app/lib/mcp/core_tools.rb](../../apps/api/app/lib/mcp/core_tools.rb)). Le handler reçoit `params:` et `caller_id:`, et doit retourner un Hash sérialisable JSON.
5. **Ajouter à `OPERATOR_SCOPES`** ([apps/api/app/controllers/mcp/tools_controller.rb](../../apps/api/app/controllers/mcp/tools_controller.rb)) si le scope est nouveau ; sinon le test `operator_scopes_spec.rb` plante au boot.
6. **Spec d'intégration** : (a) happy path via `POST /mcp/tools/<name>`, (b) test négatif sans le scope → 403 `rbac_forbidden`, (c) test d'audit → ligne écrite avec `template_id: "mcp:<name>"`.
7. **Marquer DEPRECATED** le controller REST hérité ; le retrait effectif est tracé dans le change futur `remove-rest-wrappers`.

### Exemple : migration de `POST /agent/chat` vers tool `agent_chat`

- Avant : `Agent::ChatController#create` rendait un body JSON `{ rows, citations, warnings, retrieval_path, duration_ms }`.
- Après : tool MCP `agent_chat` enregistré dans [`Mcp::CoreTools`](../../apps/api/app/lib/mcp/core_tools.rb) ; le handler appelle `retriever.call(prompt)` et renvoie le même Hash.
- Streaming : le controller [`Mcp::ToolsController`](../../apps/api/app/controllers/mcp/tools_controller.rb) détecte `Accept: text/event-stream` et bascule sur [`Mcp::AgentChatStreamer`](../../apps/api/app/lib/mcp/agent_chat_streamer.rb) qui découpe la réponse en chunks `tool_result` partiels (cf. §1.2). Le change [`add-agent-chat-streaming`](../../openspec/changes/add-agent-chat-streaming/) ajoute heartbeat keep-alive (`event: ping`), cancellation propagation (audit `client_gone`), et émission progressive optionnelle via `each_chunk`. Format détaillé et bonnes pratiques SDK consommateurs : [`docs/operating/agent-chat-streaming.md`](../operating/agent-chat-streaming.md).
- Le controller `Agent::ChatController` reste mais porte désormais l'annotation `# DEPRECATED ...`.

## Quand `remove-rest-wrappers` retire-t-il les wrappers ?

Critères avant de planifier `remove-rest-wrappers` :

- La TUI `reconautctl` utilise exclusivement MCP (sauf auth bootstrap) — vérifié par [`scripts/check_tui_mcp_only.sh`](../../scripts/check_tui_mcp_only.sh).
- Aucun consommateur externe documenté ne dépend des routes REST héritées (`/scopes`, `/agent/chat`).
- Les outils MCP correspondants sont stables depuis au moins une release.

Une fois ces critères atteints, le change `remove-rest-wrappers` :

1. Supprime `Agent::ChatController`, `ScopesController` et leurs routes.
2. Supprime les specs request `agent_chat_spec.rb` et `scopes_spec.rb` si elles ne testent que les routes REST.
3. Met à jour le linter d'allowlist en retirant la zone de transition (`TRANSITION_PATTERNS` dans [`scripts/check_rest_allowlist.sh`](../../scripts/check_rest_allowlist.sh)).

## Liens

- [Spec mcp-server (single-user-only)](../../openspec/changes/single-user-only/specs/mcp-server/spec.md) — matrice de scopes définitive en mono-user.
- [Spec mcp-server (mcp-as-primary-entrypoint)](../../openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md) — Requirement *REST API Reduced to Bootstrap, Health and MCP Transport*.
- [Spec architecture](../../openspec/changes/mcp-as-primary-entrypoint/specs/architecture/spec.md) — Requirement *MCP HTTP+SSE as Primary Entrypoint*.
- [auth-bootstrap.md](./auth-bootstrap.md) — pourquoi `/auth/*` reste REST.
- [scan-frontier.md](./scan-frontier.md) — frontière de scan, complémentaire au modèle d'auth.
- [mcp-exports.md](../operating/mcp-exports.md) — tool `export_report` (json/csv/stix2 + URL signée HMAC + one-shot download).
