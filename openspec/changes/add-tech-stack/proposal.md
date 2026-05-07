# Change : add-tech-stack

## Pourquoi
Le change fondateur `init-reconaut-platform` a posé le contrat fonctionnel des sept domaines (scanning, ai-optimization, agent-interface, mcp-server, gdpr-compliance, platform, open-source-governance) **sans figer la stack technique**. Ses spec deltas sont implementation-agnostiques.

Une décision de stack a été prise et doit maintenant être codifiée comme contrat normatif pour que tous les changes suivants se conçoivent contre une cible commune. Sans cette codification, deux changes parallèles peuvent diverger (par ex. un service de scan en Go vs Rust, ou un MCP en service séparé vs intégré au backend) et leurs interfaces deviennent incompatibles.

## Ce qui change
Le change introduit une nouvelle capacité **`architecture`** qui acte les choix de stack et les contraintes structurantes :

1. **Frontend = Vue 3 + Vite** (Composition API) — un seul framework UI livré en v1, pas de Nuxt.
2. **Backend applicatif = Ruby on Rails 8** (monolithe) — héberge l'API, l'agent conversationnel, le journal d'audit, **et le serveur MCP HTTP+SSE** (pas un service séparé).
3. **Workers de scan = Go** (Golang) — binaires statiques séparés du process Rails ; aucune logique de scan ne réside dans Rails.
4. **Communication Rails ↔ Go = GoodJob** (adapter ActiveJob backé par Postgres) — pas de RPC synchrone, pas de broker externe. Les workers Go consomment la table `good_jobs` directement via `SELECT ... FOR UPDATE SKIP LOCKED`. Le contrat est un schéma de message versionné (job request / job result).
5. **Distribution horizontale des workers** — N workers Go instanciables sans coordination explicite ; consommation au-moins-une-fois ; idempotence portée par une clé de job.

Le change met aussi à jour `openspec/project.md` pour figer la stack Vue 3 + Vite + Rails 8 + Go + GoodJob, et aligne les notes d'implémentation de `init-reconaut-platform/tasks.md`.

## Contraintes
- Le serveur MCP HTTP+SSE DOIT s'exécuter **dans le même process Rails 8** que le reste de l'API. Mutualisation de l'auth, du rate-limit, des middlewares et du journal d'audit. Le contrat HTTP+SSE de la spec `mcp-server` n'est pas modifié — seule l'implémentation est précisée.
- Aucune logique de scan ne DOIT vivre dans le code Rails. Pas de gem Ruby qui ouvre un socket vers une cible. Le scan est entièrement déporté dans les workers Go.
- Aucun appel synchrone Rails → Go (HTTP, gRPC, RPC propriétaire). Toute interaction passe par GoodJob.
- **Pas de broker externe.** La file de jobs vit dans le même cluster Postgres que le reste des données (TimescaleDB, pgvector, AGE), exploitant GoodJob côté Rails (table `good_jobs`) et `SELECT ... FOR UPDATE SKIP LOCKED` côté Go. La résidence des données de file suit donc automatiquement la résidence Postgres déclarée par l'opérateur (cf. `gdpr-compliance`).
- Les workers Go DOIVENT pouvoir tourner en plusieurs instances simultanément, le verrou ligne Postgres garantissant qu'un job est traité par un seul worker à la fois.
- Le contrat de message scan (job + résultat) DOIT être versionné explicitement (champ `schema_version`) pour permettre l'évolution sans rupture.

## Non-objectifs (hors scope de ce change)
- Choix de l'ORM/driver Postgres côté Go (`pgx`, `database/sql` + `lib/pq`, `sqlc`) — interne au worker, sans impact sur le contrat.
- Choix précis du runtime de consommation côté Go (poller maison sur `good_jobs` vs lib qui implémente le pattern `FOR UPDATE SKIP LOCKED`) — interne au worker, pas de norme imposée.
- Implémentation effective des workers de scan, des sondeurs de protocole, des composants Vue, du Rails app — ce change pose le contrat, pas l'implémentation.

## Décisions prises
1. **MCP dans Rails** — Le serveur MCP HTTP+SSE est un endpoint Rails (controller streaming SSE), pas un microservice. Justification : un seul périmètre d'auth, un seul journal d'audit, un seul gestionnaire de rate-limit ; éviter la duplication de logique sensible (RBAC, audit immuable) qui devrait sinon être synchronisée entre deux services.
2. **GoodJob (Postgres) plutôt qu'un broker externe ou Solid Queue** — Justification : GoodJob est l'adapter ActiveJob Postgres-backed le plus mature (production-ready depuis 2020, modèle single-table simple `good_jobs`, dispatch low-latency via LISTEN/NOTIFY). Supprime une dépendance d'infrastructure (Redis / RabbitMQ / NATS / Kafka), et résout d'office la résidence des données de file (même cluster Postgres). Solid Queue (défaut Rails 8) reste plus jeune ; GoodJob a un modèle de table plus simple à consommer depuis Go. La latence et le débit sont suffisants pour un scope-driven scanner self-hosted.
3. **Pas de logique de scan dans Rails** — Frontière dure entre plan applicatif (Rails) et plan exécution (Go). Justification : isolation de fault (un panic Go ne tue pas l'API), perf (binaires Go statiques à fort débit, déploiement simple), et substituabilité (le contrat de message permet de remplacer un worker Go par un autre langage si nécessaire — mais l'inverse, dissoudre le scan dans Rails, casserait l'isolation).
4. **Go plutôt que Rust pour les workers** — Justification : écosystème réseau standard riche (`net/http`, `crypto/tls`), build statique simple multi-arch sans toolchain croisée complexe, courbe d'apprentissage plus douce pour les contributeurs OSS, GC adapté aux workloads I/O-bound de scan. La sûreté mémoire absolue de Rust n'est pas critique sur des sondeurs réseau qui parlent à des cibles non hostiles par construction (scope-driven).
5. **Vue 3 + Vite, pas de Nuxt** — Justification : SPA simple sans besoin de SSR ; Vite suffit pour le bundle ; Nuxt ajouterait une couche de complexité sans bénéfice produit (l'application est derrière auth, pas indexable).

## Différé (non bloquant, parqué pour plus tard)
- **Mécanisme de back-pressure** — Comment Rails ralentit l'acceptation de nouveaux scans quand la file GoodJob dépasse un seuil. Pattern à acter au change `scan-engine`.
- **Tuning GoodJob** — paramètres de polling, partitionnement par `queue_name`, isolation par niveau de priorité, exploitation du `LISTEN/NOTIFY` côté Go — à mesurer une fois la v1 livrée.
