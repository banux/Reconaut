# Tâches : add-tech-stack

Checklist d'adoption de la stack Vue.js + Rails + Rust + file de jobs. Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Documentation et alignement de contexte

- [ ] **1.1 Mettre à jour `openspec/project.md`**
  - **Notes** : Remplacer la section *Stack (existante et prévue)* qui mentionne Python 3.12 / FastAPI / aiohttp. Nouvelle section :
    - **Frontend** : Vue.js 3 (Composition API), Vite, Pinia (état), Vue Router.
    - **Backend** : Ruby on Rails (version à figer en 1.2), héberge l'API tenant, l'agent conversationnel, la facturation, le journal d'audit et le serveur MCP HTTP+SSE dans le même process.
    - **Workers de scan** : Rust (édition stable la plus récente), binaires séparés, communication Rails ↔ Rust uniquement via file de jobs.
    - **Broker** : file de jobs distribuée EU-hébergée, choix concret différé.
    - **Stockage** : Postgres + extensions TimescaleDB et pgvector ; stockage objet S3-compatible EU.
    - **Embeddings** : `mistral-embed` (inchangé).
    - **MCP** : SDK Ruby ou implémentation maison HTTP+SSE intégrée à Rails ; transport HTTP+SSE uniquement.
  - **Test plan** : `grep -RniE "fastapi|aiohttp|uv\.lock|pyproject\.toml" openspec/project.md` ne renvoie aucune occurrence ; `openspec validate` (ou commande équivalente du CLI OpenSpec) passe sur le projet.

- [ ] **1.2 Figer la version exacte de Rails et de Vue**
  - **Notes** : Décider Rails 7.x vs 8.x (préférence : la dernière LTS au moment du bootstrap) et Vue 3.x avec ou sans Nuxt. Ajouter une ligne dans `project.md` sous *Stack*.
  - **Test plan** : `project.md` contient une ligne explicite `Rails X.Y` et `Vue 3.x (Vite, sans Nuxt)` ou `Vue 3.x via Nuxt N` ; revue humaine confirme.

- [ ] **1.3 Aligner les notes d'implémentation de `init-reconaut-platform/tasks.md`**
  - **Notes** : Les tâches 1.1, 1.2, 2.x, 4.x, 5.x, 7.x mentionnent `uv`, `pytest`, `mypy`, `FastAPI`, `aiohttp`, `SQLModel`, `pybreaker`, `aiodns`. Réécrire les *Notes* et *Test plan* pour refléter Rails (RSpec/Minitest, Sorbet ou `rbs` pour le typage si retenu, Active Record, gem `circuit_box` ou équivalent, gem DNS) et Rust (cargo, criterion pour bench, sondeurs en Rust). Ne pas toucher aux spec deltas (qui sont implementation-agnostiques).
  - **Test plan** : `grep -RniE "fastapi|aiohttp|sqlmodel|uv run|pyproject" openspec/changes/init-reconaut-platform/tasks.md` ne renvoie aucune occurrence ; chaque ancienne mention Python a un remplacement Rails ou Rust avec sa contrepartie d'outillage de test.

---

## 2. Bootstrap monorepo conforme à la stack — spec : `architecture`

- [ ] **2.1 Layout monorepo Rails + Vue + Rust**
  - **Notes** : Structure cible :
    - `apps/api/` : Rails monolithe (API tenant, agent, MCP, billing, audit). MCP exposé sous une route Rails (par ex. `mount Mcp::Engine, at: "/mcp"`) dans le même process.
    - `apps/web/` : Vue 3 + Vite, dossier indépendant, déploiement statique sur CDN EU.
    - `apps/scanner/` : workspace Cargo Rust avec un binaire `scanner-worker` et une crate `scan-protocols` réutilisable.
    - `packages/job-schema/` : définitions de schéma de message (JSON Schema ou ProtoBuf), versionnées, consommées à la fois par Rails (codegen ou parsing JSON) et par Rust (codegen via `serde` ou `prost`).
    - `Dockerfile` par app, `docker-compose.yml` racine pour le dev local (Postgres + broker + Rails + scanner).
  - **Test plan** : `bin/setup` racine installe Ruby (via `mise`/`asdf`), Node (pour Vue), Rust (via `rustup`) ; `bin/test` exécute en parallèle `cd apps/api && bundle exec rspec`, `cd apps/web && pnpm test`, `cd apps/scanner && cargo test` ; chaque suite contient un test smoke trivial qui passe.

- [ ] **2.2 Pipeline CI multi-stack (GitHub Actions)**
  - **Notes** : Jobs séparés par app : `api-rubocop`, `api-rspec`, `web-eslint`, `web-vitest`, `scanner-clippy`, `scanner-cargo-test`, build d'image par app. Cache des dépendances (Bundler, pnpm/npm, cargo) keyé par lockfile.
  - **Test plan** : Ouvrir une PR triviale ; tous les jobs verts. Introduire une violation `clippy::all` dans une crate Rust et vérifier que `scanner-clippy` échoue ; introduire une violation Rubocop côté Rails et vérifier que `api-rubocop` échoue.

- [ ] **2.3 Linter de stack (rejette les violations de l'exigence `architecture`)**
  - **Notes** : Script CI `scripts/check_stack.sh` qui :
    - rejette tout fichier `.jsx`/`.tsx` ou import `react` dans `apps/web/`,
    - rejette toute gem cliente RPC vers les workers (regex sur `Gemfile.lock` pour les patterns `grpc`, `scanner-client`, etc.),
    - rejette tout import direct de `Socket`/`Net::HTTP`/`OpenSSL::SSL::SSLSocket` dans le code Rails à l'exception d'une allowlist documentée (Mistral, Stripe, IdP OIDC, broker, audit, healthcheck),
    - rejette tout fichier `.py`/`pyproject.toml`/`uv.lock` dans le repo.
  - **Test plan** : `scripts/check_stack.sh` exécuté à propre passe (exit 0). Test du linter : créer un fichier `apps/web/src/Bad.jsx`, lancer le script, vérifier exit ≠ 0 avec message `frontend-stack-violation`. Idem pour un import `Net::HTTP.get(host_url)` dans le contrôleur API.

---

## 3. Contrat de message scan — spec : `architecture`

- [ ] **3.1 Schéma de message versionné (`packages/job-schema/`)**
  - **Notes** : Définir au minimum trois schémas — `ScanJobV1`, `ScanResultV1`, `Heartbeat` — avec un champ `schema_version: u32`, une `idempotency_key: string`, un `tenant_id: string`, un `target: { kind, value }`, et un `requested_at: rfc3339`. Format au choix (JSON Schema + serde_json ou ProtoBuf + prost) — tracer la décision dans le README du package.
  - **Test plan** : Test de round-trip Rails → wire → Rust qui sérialise un `ScanJobV1` côté Rails, le désérialise côté Rust, vérifie l'égalité champ par champ. Test négatif : un message avec `schema_version=99` est rejeté côté worker avec une erreur explicite (pas un silent skip).

- [ ] **3.2 Stub de publication côté Rails et stub de consommation côté Rust**
  - **Notes** : Couche d'abstraction `JobBus` côté Rails (interface `publish(topic, message)`) et trait `JobBus` côté Rust (méthode `consume(topic) -> Stream<Message>`) — implémentations concrètes différées au choix du broker. Implémentation in-memory pour les tests.
  - **Test plan** : Test d'intégration Rails publie 3 jobs sur un `JobBus` in-memory ; un consommateur Rust en process (via FFI de test ou tests partagés) récupère exactement 3 messages dans l'ordre. Aucun appel HTTP/gRPC sortant n'est observé (vérifié par un mock outbound).

---

## 4. Intégration MCP dans Rails — spec : `architecture` + `mcp-server`

- [ ] **4.1 Engine Rails dédié au MCP partageant la pile de middlewares**
  - **Notes** : Implémenter `apps/api/engines/mcp` (Rails Engine ou namespace de routes). Les outils `search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report` sont des controllers Rails. Le streaming SSE utilise `ActionController::Live`. La couche d'auth par clé API tenant est partagée avec l'API REST (un seul `before_action :authenticate_tenant_key!`).
  - **Test plan** : Test d'intégration appelle `search_hosts` via MCP et `GET /hosts` via API REST avec la même clé API ; assure que les deux passent par le même journal d'audit (même schéma de ligne, même `key_id`). Test négatif : appel MCP avec une clé révoquée renvoie la même erreur structurée que l'API REST.

- [ ] **4.2 `request_scan` publie un job au lieu d'appeler un worker**
  - **Notes** : L'outil `request_scan` ne contient aucune logique de scan ; il valide les paramètres, vérifie le scope de la clé, écrit une ligne d'audit et publie un message `ScanJobV1` sur la file. Renvoie immédiatement le `scan_id`.
  - **Test plan** : Test d'intégration appelle `request_scan` avec une cible valide ; assure (a) HTTP 200 et `scan_id` renvoyé en < 100 ms, (b) un message a été publié sur le `JobBus` in-memory avec une `idempotency_key` dérivée de `(tenant_id, target, requested_at_minute)`, (c) aucun appel sortant vers un worker Rust n'a eu lieu.

---

## 5. Worker Rust de référence (squelette) — spec : `architecture`

- [ ] **5.1 Squelette de worker consommant la file et persistant un résultat**
  - **Notes** : Crate `scanner-worker` qui (a) se connecte au `JobBus`, (b) consomme `ScanJobV1`, (c) effectue un no-op de scan en v1 (placeholder pour les vrais sondeurs livrés au change `scan-engine`), (d) publie `ScanResultV1`. Idempotence : table de déduplication locale ou côté broker selon le pattern broker.
  - **Test plan** : Test d'intégration lance 2 workers sur un `JobBus` in-memory, publie 100 jobs (dont 10 doublons par `idempotency_key`) ; assure que (a) tous les jobs uniques sont traités, (b) les doublons sont détectés et acquittés sans seconde écriture, (c) la charge est répartie (chaque worker traite > 30 % du volume unique).

- [ ] **5.2 Gestion de panique sans contamination**
  - **Notes** : Un panic dans la consommation d'un message ne tue pas le worker entier ; le message est remis en file ou envoyé en DLQ après N tentatives.
  - **Test plan** : Injecter un message qui force un panic dans un sondeur ; assurer que (a) le worker continue de consommer les messages suivants, (b) après 3 tentatives le message va en DLQ, (c) un compteur Prometheus `scan_worker_panics_total` est incrémenté.

---

## 6. Documentation et runbooks

- [ ] **6.1 Documentation de la frontière Rails ↔ Rust**
  - **Notes** : Page de doc interne décrivant le contrat de message, la liste des schémas versionnés, comment ajouter un nouveau type de scan (créer le schéma, le publier dans `packages/job-schema`, implémenter le worker Rust, ne JAMAIS le coder côté Rails).
  - **Test plan** : La page existe sous `docs/architecture/scan-frontier.md` et est référencée depuis le README racine.

- [ ] **6.2 Runbook : ajouter un nouveau worker Rust en production**
  - **Notes** : Étapes pour déployer N workers supplémentaires, les rattacher au broker EU, vérifier qu'ils consomment bien, et les retirer proprement (drain).
  - **Test plan** : Le runbook existe et a été exécuté manuellement une fois en environnement de staging avec capture d'écran de l'avant/après dans le journal de runbook.

---

## Acceptation pour le change dans son ensemble

- [ ] Chaque exigence du spec delta `architecture` a au moins un test automatisé passant en CI.
- [ ] Le linter de stack (`scripts/check_stack.sh`) tourne en CI sur chaque PR et bloque les fusions qui introduisent React, Net::HTTP vers une cible, ou un client RPC synchrone vers les workers.
- [ ] `openspec/project.md` ne contient plus de référence à FastAPI / aiohttp / uv ; les notes de `init-reconaut-platform/tasks.md` sont alignées sur Rails + Rust.
- [ ] Une commande `bin/doctor` (ou équivalent Rake task `rails reconaut:doctor`) imprime : version Rails, version Rust embarquée, région du broker connectée, dernier `schema_version` connu côté Rails et côté Rust.
