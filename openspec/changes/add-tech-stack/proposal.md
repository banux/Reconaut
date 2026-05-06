# Change : add-tech-stack

## Pourquoi
Le change fondateur `init-reconaut-platform` a posé le contrat fonctionnel des six domaines (scanning, ai-optimization, agent-interface, mcp-server, gdpr-compliance, platform) **sans figer la stack technique**. Ses spec deltas sont implementation-agnostiques ; seuls `project.md` et les notes de `tasks.md` mentionnaient une stack provisoire en Python/FastAPI/aiohttp.

Une décision de stack a été prise le 2026-05-05 et doit maintenant être codifiée comme contrat normatif pour que tous les changes suivants se conçoivent contre une cible commune. Sans cette codification, deux changes parallèles peuvent diverger (par ex. un service de scan en Go vs Rust, ou un MCP en service séparé vs intégré au backend) et leurs interfaces deviennent incompatibles.

## Ce qui change
Le change introduit une nouvelle capacité **`architecture`** qui acte les choix de stack et les contraintes structurantes :

1. **Frontend = Vue.js** (3.x) — un seul framework UI livré en v1.
2. **Backend applicatif = Ruby on Rails** — héberge l'API tenant, l'agent conversationnel, le journal d'audit, **et le serveur MCP HTTP+SSE** (pas un service séparé).
3. **Workers de scan = Rust** — binaires séparés du process Rails ; aucune logique de scan ne réside dans Rails.
4. **Communication Rails ↔ Rust = file de jobs distribuée** — pas de RPC synchrone. Le contrat est un schéma de message versionné (job request / job result). Le broker doit être EU-hébergé.
5. **Distribution horizontale des workers** — N workers Rust instanciables sans coordination explicite ; consommation au-moins-une-fois ; idempotence portée par une clé de job.

Le change met aussi à jour `openspec/project.md` pour remplacer la section *Stack* (qui mentionne Python/FastAPI/aiohttp) par la stack Vue/Rails/Rust, et aligne les notes d'implémentation de `init-reconaut-platform/tasks.md` qui font référence à `uv`, `pytest`, `mypy`, etc.

## Contraintes
- Le serveur MCP HTTP+SSE DOIT s'exécuter **dans le même process Rails** que l'API tenant. Mutualisation de l'auth, du rate-limit, des middlewares et du journal d'audit. Le contrat HTTP+SSE de la spec `mcp-server` n'est pas modifié — seule l'implémentation est précisée.
- Aucune logique de scan ne DOIT vivre dans le code Rails. Pas de gem Ruby qui ouvre un socket vers une cible. Le scan est entièrement déporté dans les workers Rust.
- Aucun appel synchrone Rails → Rust (HTTP, gRPC, RPC propriétaire). Toute interaction passe par la file de jobs.
- Le broker de jobs DOIT être hébergé dans la liste blanche de régions EU/EEE de la spec `gdpr-compliance` et persister les messages chez un fournisseur EU.
- Les workers Rust DOIVENT être déployables dans plusieurs régions EU simultanément (cohérent avec la décision multi-actif EU). Un job émis dans `eu-west-3` peut être consommé par un worker dans `eu-central-1` si la politique de routing le permet.
- Le contrat de message scan (job + résultat) DOIT être versionné explicitement (champ `schema_version`) pour permettre l'évolution sans rupture.

## Non-objectifs (hors scope de ce change)
- Choix concret du broker (NATS / Redis Streams / RabbitMQ / Kafka) — différé au change `scan-engine` qui sera le premier consommateur réel.
- Choix de la version exacte de Rails (7.x vs 8.x) et de Vue (Vue 3 + Composition API supposé, mais variantes Nuxt/Vite à trancher au change `frontend-bootstrap`).
- Choix de l'ORM Rust côté worker (sqlx, diesel, sea-orm) — interne au worker, sans impact sur le contrat.
- Implémentation effective des workers de scan, des sondeurs de protocole, des composants Vue, du Rails app — ce change pose le contrat, pas l'implémentation.
- Migration depuis un éventuel prototype Python existant — il n'y en a pas dans le repo.

## Décisions prises
1. **MCP dans Rails** — Le serveur MCP HTTP+SSE est un endpoint Rails (controller streaming SSE), pas un microservice. Justification : un seul périmètre d'auth tenant, un seul journal d'audit GDPR, un seul gestionnaire de rate-limit ; éviter la duplication de logique sensible (RBAC, audit immuable) qui devrait sinon être synchronisée entre deux services.
2. **File de jobs (et non RPC)** — Choix d'une queue distribuée plutôt qu'un appel HTTP/gRPC synchrone Rails → Rust. Justification : le scan est par nature long, asynchrone, distribué, sujet à pics ; la queue absorbe les bursts, permet le scaling horizontal indépendant des workers, et survit aux redémarrages de workers sans perte. Découplage temporel = résilience.
3. **Pas de logique de scan dans Rails** — Frontière dure entre plan applicatif (Rails) et plan exécution (Rust). Justification : sécurité (parsers en mémoire-sûre), perf (workers Rust à fort débit), et substituabilité (le contrat de message permet de remplacer un worker Rust par un autre langage si nécessaire — mais l'inverse, dissoudre le scan dans Rails, casserait l'isolation).

## Différé (non bloquant, parqué pour plus tard)
- **Choix du broker concret** — NATS JetStream, Redis Streams, RabbitMQ Quorum Queues, Apache Kafka. Critères : débit (>10k msg/s soutenu), résidence EU managée ou auto-hébergeable EU, garanties d'ordering par clé d'idempotence, durabilité (persist-to-disk). À trancher au change `scan-engine`.
- **Topologie de routing par région** — Une queue globale avec workers multi-région, ou une queue par région avec routing ? Décision liée au broker choisi.
- **Mécanisme de back-pressure** — Comment Rails apprend que la file est saturée et ralentit l'acceptation de nouveaux scans. Pattern à acter au change `scan-engine`.
