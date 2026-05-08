# Auth bootstrap REST — pourquoi les routes `/auth/*` restent REST

Statut : **stable, volontairement non migrable vers MCP**.
Source de vérité : [`mcp-as-primary-entrypoint`](../../openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md) — Requirement *REST API Reduced to Bootstrap, Health and MCP Transport*.

## Contexte

Reconaut acte que **MCP HTTP+SSE est le canal d'entrée principal** ([`mcp-as-primary-entrypoint`](../../openspec/changes/mcp-as-primary-entrypoint/proposal.md)). Toute opération métier — gestion de scope, scan, recherche d'hôtes, agent conversationnel, doctor, gestion des clés API — passe par un outil MCP. La TUI `reconautctl` consomme ces outils ; les agents IA externes les consomment ; les scripts CI les consomment.

Trois familles d'endpoints REST restent en place et **ne migreront pas** vers MCP :

| Famille          | Routes                                                                | Raison de rester REST                                                                                       |
|------------------|-----------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| Auth bootstrap   | `POST /auth/sessions`, `POST /auth/api_keys`, `DELETE /auth/api_keys/:id` | Œuf et poule de la clé API : on n'a, par construction, **pas encore** de clé API à présenter à MCP au login. |
| Healthcheck      | `GET /healthz`                                                        | Probe non authentifié (LB / k8s / blackbox prometheus). Pas de notion d'identité.                            |
| Transport MCP    | `/mcp/*`                                                              | C'est le transport MCP HTTP+SSE lui-même.                                                                    |

## Pourquoi l'auth bootstrap reste REST

### 1. Œuf et poule de la clé API

L'authentification MCP exige un header `Authorization: Bearer <api_key>`. Or, à l'instant où un opérateur tape `reconautctl login` pour la **première fois**, il n'a pas encore de clé API : c'est précisément ce qu'il essaie d'obtenir.

Faire passer le bootstrap par MCP demanderait :

- soit d'autoriser des appels MCP **sans** clé (et d'ajouter une exception "endpoint d'émission de clé"),
- soit d'inventer un canal MCP pré-clé avec son propre mécanisme d'auth (login/password, OIDC),

ce qui dans les deux cas multiplie la surface d'auth qu'on a justement décidé de mutualiser.

### 2. Audit séparé du bootstrap

Le bootstrap est un événement à part : tentative de login (succès ou échec), génération d'une nouvelle clé API, révocation. Ces évènements DOIVENT être audités, mais avec un schéma volontairement distinct des invocations MCP — `actor=<email>`, `action=auth.bootstrap`, `outcome=success|failure`. Garder un controller dédié (`Auth::SessionsController`, `Auth::ApiKeysController`) rend ce séparé naturellement.

### 3. Simplicité opérationnelle

- L'opérateur peut révoquer une clé directement via REST (`DELETE /auth/api_keys/:id`) **même si** sa clé courante est compromise et qu'il préfère une voie courte.
- Les outils standards (`curl`, `httpie`, navigateur) marchent contre `/auth/*` sans avoir besoin d'un client MCP.

### 4. Une seule clé API par opérateur

`POST /auth/api_keys` génère une **seule clé personnelle** par opérateur, valable pour TOUS les usages (TUI et agents IA). Cette décision (cf. spec [`platform`](../../openspec/changes/mcp-as-primary-entrypoint/specs/platform/spec.md) — *Authentication and RBAC*) découle directement de l'architecture mono-utilisateur ([`single-user-only`](../../openspec/changes/single-user-only/proposal.md)) : un opérateur, un trousseau, un canal d'audit unifié.

## Contrat des endpoints

### `POST /auth/sessions`

**But** : échanger un email + password (ou un password seul en mode mono-user) contre une session courte ET une clé API personnelle nouvellement générée.

**Body** :

```json
{ "email": "ops@example.com", "password": "..." }
```

ou en mono-user :

```json
{ "password": "..." }
```

**Réponse 201** :

```json
{
  "user":    { "id": "...", "email": "...", "role": "operator" },
  "api_key": { "id": "...", "prefix": "rk_...", "secret": "<one-time>" }
}
```

**Réponse 401** : `{ "error": "invalid_credentials" }`.

### `POST /auth/api_keys`

**But** : générer une clé API personnelle supplémentaire (ex. clé read-only pour un agent IA externe). Requiert une session valide ou la clé courante.

**Body** : `{ "scopes": ["read:hosts", "read:scans"] }` (optionnel ; le défaut est full-scope cf. [`single-user-only`](../../openspec/changes/single-user-only/specs/mcp-server/spec.md)).

### `DELETE /auth/api_keys/:id`

**But** : révoquer explicitement une clé. Utile quand l'opérateur a perdu sa clé courante et veut la couper rapidement, sans devoir d'abord récupérer une nouvelle clé pour appeler le tool MCP `revoke_api_key`.

## Pourquoi le linter d'allowlist autorise CE périmètre et rien d'autre

Le linter [`scripts/check_rest_allowlist.sh`](../../scripts/check_rest_allowlist.sh) bloque toute nouvelle route REST hors de :

- `POST /auth/sessions`, `DELETE /auth/sessions/:id`
- `POST /auth/api_keys`, `DELETE /auth/api_keys/:id`
- `GET /healthz` (et `GET /up` legacy Rails)
- `/mcp/*`

**Toute autre feature DOIT être ajoutée comme outil MCP**. Le linter est volontairement strict : si une feature ne rentre pas dans MCP (rare), elle exige une PR explicite qui amende l'allowlist, avec justification.

## Lien avec d'autres changes

- [`mcp-as-primary-entrypoint`](../../openspec/changes/mcp-as-primary-entrypoint/) : ce document sert de référence à la décision de figer l'auth bootstrap en REST.
- [`single-user-only`](../../openspec/changes/single-user-only/) : modèle mono-utilisateur, simplifie le contrat de `POST /auth/sessions`.
- [`replace-web-with-tui`](../../openspec/changes/replace-web-with-tui/) : la TUI `reconautctl` est le client REST de référence pour le bootstrap (et le client MCP pour le reste).
- Future change `remove-rest-wrappers` : retire `ScopesController` / `Agent::ChatController` une fois la TUI stabilisée sur MCP. **Ne touche pas** aux endpoints décrits ici.
