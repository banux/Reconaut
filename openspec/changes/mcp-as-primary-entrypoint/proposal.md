# Change : mcp-as-primary-entrypoint

## Pourquoi

Le change `replace-web-with-tui` retire la SPA et la remplace par un binaire Go. Implicitement, ce binaire devait dialoguer avec l'API REST Rails. Cette décision laisse coexister **deux surfaces d'exposition** différentes sur le serveur — l'API REST côté `/scopes`, `/scans`, `/agent/chat`, et le serveur MCP côté `/mcp/*` — qui dupliquent la couverture fonctionnelle (chacune offre `request_scan`, chacune offre des recherches d'hôtes, etc.). Cette duplication est coûteuse :

1. **Double surface d'authentification, audit et rate-limit** à durcir, alors qu'on a déjà décidé de mutualiser tout ça dans le process Rails. Une route MCP et une route REST « équivalente » ont en pratique des middlewares un peu différents et les invariants finissent par diverger.
2. **Double surface de schéma** : chaque feature doit être déclarée comme controller REST + outil MCP, avec des contrats de réponse différents (JSON pur vs MCP `tool_result` avec métadonnées).
3. **Double point de friction pour les agents IA** qui veulent automatiser (l'API REST n'est pas aussi bien documentée et instrumentée que MCP côté tooling, par construction).

L'utilisateur acte donc que le **point d'entrée principal est le serveur MCP HTTP+SSE**. La TUI `reconautctl`, les agents IA externes et tout futur client (CI scripts, intégrations) consomment **le même périmètre d'outils MCP** avec la même clé API personnelle. L'API REST se réduit au strict nécessaire que MCP ne peut pas fournir : le bootstrap d'auth (impossible d'invoquer un outil MCP avant d'avoir une clé), le healthcheck non authentifié, et le transport MCP lui-même.

## Ce qui change

1. **MCP devient l'unique surface fonctionnelle**. Le périmètre des outils MCP s'étend pour couvrir l'intégralité du workflow opérateur :
   - **Scope** : `list_scopes`, `add_scope`, `revoke_scope`
   - **Scans** : `request_scan` (déjà), `get_scan_status` (déjà), `list_scans`
   - **Hosts** : `search_hosts` (déjà), `get_host` (déjà)
   - **Agent** : `agent_chat` (streaming SSE pour la réponse — le transport MCP HTTP+SSE supporte nativement le stream de chunks)
   - **Reports** : `export_report` (déjà)
   - **Admin** : `list_users`, `grant_role`, `revoke_role`, `list_api_keys`, `revoke_api_key`
   - **Doctor** : `system_doctor` (renvoie le rapport `Reconaut::Doctor` JSON-sérialisé)
2. **L'API REST se restreint** à trois familles d'endpoints **non-MCP** :
   - **Auth bootstrap** : `POST /auth/sessions` (échange email + password contre une session ou une clé API), `POST /auth/api_keys` (génération de clé API personnelle), `DELETE /auth/sessions/{id}` (logout). Ces endpoints sont nécessaires car un client n'a, par construction, pas encore de clé API quand il s'authentifie.
   - **Healthcheck** : `GET /healthz` non authentifié, renvoie `200 OK` si le process Rails sert du trafic. Sans body sensible.
   - **Transport MCP** : les routes `/mcp/*` qui portent le serveur MCP HTTP+SSE.
   Tout autre controller REST hérité (par ex. `ScopesController`, `Agent::ChatController`) DOIT être supprimé ou réduit à un wrapper qui invoque l'outil MCP correspondant côté Rails (option transitoire).
3. **La TUI `reconautctl` consomme MCP**, pas REST. Au lieu d'avoir un `internal/api/` qui parle un dialecte REST maison, le binaire embarque un client MCP Go qui invoque les outils par nom. Une seule couche de sérialisation, un seul endpoint d'audit côté serveur.
4. **Spec `mcp-server` étendue** pour énumérer le set noyau de tools couvrant le workflow opérateur, ainsi que les scopes RBAC associés.

## Contraintes

- **MCP HTTP+SSE est le canal de référence**. Toute nouvelle feature opérateur ajoutée au produit DOIT s'exposer comme outil MCP avant tout autre canal. Pas de controller REST nouveau hors auth-bootstrap / healthz / transport MCP.
- **Une seule clé API personnelle** par opérateur, valable pour TUI et agents IA. Pas de séparation `tui_key` vs `mcp_key`.
- **Streaming via SSE de MCP** plutôt que routes REST streaming : `agent_chat` retourne ses chunks via le mécanisme `tool_result` streaming du transport MCP HTTP+SSE, pas via une route `/agent/chat` REST séparée.
- **Auth bootstrap reste REST** parce qu'il faut bien un canal pré-clé API. Cet ensemble de routes est volontairement minimal : login, logout, génération de clé, et c'est tout.
- **Le linter de stack** qui contrôle l'absence de SPA s'étend pour rejeter l'introduction d'un nouveau controller REST hors de l'allowlist (auth-bootstrap, healthz, MCP transport). Toute nouvelle route REST exige donc un changement explicite de l'allowlist.
- **Audit unifié** : chaque outil MCP écrit une ligne d'audit (déjà spécifié). Les endpoints REST restants (auth bootstrap, healthz) sont audités séparément avec leurs propres lignes mais le même schéma de table.
- **Pas de regression sur le rate-limit ni sur la résilience** : le serveur MCP doit absorber les pics de TUI + agents IA simultanés. Pour la v1 on tolère un middleware rate-limit unique sur l'ensemble des outils MCP, la spécialisation par tool est différée.

## Non-objectifs (hors scope de ce change)

- **Réécriture du transport MCP** (HTTP+SSE est figé par `init-reconaut-platform`/`mcp-server`). Ce change n'introduit pas de nouveau transport.
- **MCP « stdio »** — toujours hors scope.
- **GraphQL ou autre alternative à MCP** — délibérément exclu : MCP est le canal.
- **MCP pour l'auth bootstrap** (genre un outil `login` qui accepte un mot de passe). Volontairement exclu : l'auth bootstrap reste REST pour rester simple et auditer ce chemin séparément.
- **Suppression complète de l'API REST en v1**. Les controllers existants peuvent rester en mode wrapper/transition pendant la migration, le linter qui empêche les *nouvelles* routes REST suffit à fixer la trajectoire. Le retrait des wrappers est un cleanup ultérieur.
- **Gestion fine des permissions par tool dans la même ligne d'audit** (matrice détaillée des scopes par tool) — déjà couverte par `mcp-server` spec existant ; ce change ajoute des tools sans réécrire le mécanisme.

## Décisions prises

1. **MCP HTTP+SSE = canal opérateur principal.** Tout client (humain via TUI, agent IA via SDK MCP, CI script) parle MCP. Justifié par l'unification d'auth/audit/rate-limit côté serveur, par la cohérence du contrat de réponse, et par le fait que MCP est déjà la surface AI-first sur laquelle Reconaut se positionne.
2. **API REST réduite à un strict triple : auth bootstrap, healthz, transport MCP.** Justifié par l'incapacité technique de MCP à porter le bootstrap (œuf et poule de la clé API) et par la nécessité opérationnelle d'un endpoint de healthcheck pour load-balancer / k8s probes.
3. **Une seule clé API par opérateur**, partagée TUI et MCP-AI. Justifié par la simplicité opérationnelle (l'opérateur révoque une seule clé pour couper tout accès) et par l'invariant déjà figé du modèle tenant unique (un opérateur = un périmètre = un trousseau de clés).
4. **`agent_chat` devient un outil MCP streaming** (et plus une route REST SSE séparée). Justifié par la simplicité : le transport MCP HTTP+SSE supporte déjà les `tool_result` partiels en streaming, donc on n'a pas besoin d'une seconde implémentation SSE.
5. **Linter d'allowlist REST** plutôt qu'une suppression dure des controllers existants. Justifié par la pragmatique : la migration est progressive ; le linter empêche la régression pendant que les wrappers sont retirés un par un.

## Différé (non bloquant, parqué pour plus tard)

- **Retrait effectif des controllers REST hérités** (`ScopesController`, `Agent::ChatController`, etc.). Tracé dans un change ultérieur `remove-rest-wrappers` une fois que la TUI est stable sur MCP et qu'aucun consommateur externe ne dépend des routes REST.
- **MCP rate-limit par outil** (par ex. `agent_chat` plus permissif que `request_scan`). Différé jusqu'à mesure des hot paths.
- **Versionnage des outils MCP** (`search_hosts.v2` etc.) — pas nécessaire en v1, à acter quand un breaking change arrive.
- **Partial `tool_result` streaming** côté SDK Ruby MCP côté serveur — implémentation à acter selon ce que le SDK retenu supporte.
