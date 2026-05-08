# Reconaut — Contexte projet

Reconaut est un **outil open source auto-hébergeable** d'Attack Surface Management : il scanne le périmètre d'actifs internet **explicitement déclaré par l'opérateur** (CIDR, domaines, hôtes), avec l'IA comme capacité de premier ordre — pas un ajout cosmétique. Pas de balayage du grand internet, pas de collecte de données sur des tiers non consentants : l'opérateur ne scanne que ce qu'il possède ou contrôle.

## Positionnement

- **Open source, auto-hébergeable.** Reconaut est une **base de connaissance d'actifs internet** maintenue par son opérateur, queryable par ses agents IA et intégrable à sa stack sécurité. **Mono-user** par construction : une instance = un opérateur = un périmètre d'actifs. Un opérateur qui veut isoler plusieurs périmètres déploie plusieurs instances.
- **Scope-driven.** Le scanner refuse par construction de scanner une cible hors de la liste d'autorisation déclarée par l'opérateur. Pas de découverte du grand internet « à la Shodan ».
- **Boundary RGPD claire.** L'opérateur est le responsable de traitement (controller). Reconaut fournit les outils pour qu'il tienne ses obligations (journal d'audit, effacement, résidence configurable), mais ne porte pas la responsabilité de conformité à sa place.

## Différenciateurs

- **Optimisation des scans pilotée par IA** — planification adaptative pondérée par taux de churn, criticité déclarée par l'opérateur et fraîcheur ; détection d'anomalies sur les profils de services par hôte.
- **Interface agent conversationnelle** — recherche en langage naturel sur le jeu de données indexé, propulsée par une couche d'embeddings **pluggable** (défaut self-hostable ; Mistral / OpenAI-compatible disponible si l'opérateur le configure).
- **Serveur MCP** — expose des outils de scan, de recherche et de reporting pour que les agents IA de l'opérateur automatisent les workflows ASM.
- **Auto-hébergement sans condition.** Aucune fonctionnalité critique du produit ne dépend d'un service propriétaire externe. Tout ce qui est externe (LLM, IdP) est substituable et l'opérateur peut tourner 100 % en réseau privé.

## Stack

- **Frontend** : Vue 3 (Composition API) + Vite. Pas de Nuxt en v1.
- **Backend applicatif** : Ruby on Rails 8 (monolithe) — héberge l'API, l'agent conversationnel, le journal d'audit et le serveur MCP HTTP+SSE dans le même process.
- **Workers de scan** : Go (Golang), binaires statiques séparés du process Rails. Communication Rails ↔ Go uniquement via la file de jobs.
- **File de jobs** : **GoodJob** (adapter ActiveJob backé par Postgres, mature et éprouvé en production). Aucun broker externe (pas de Redis / RabbitMQ / NATS / Kafka). Les workers Go consomment la table `good_jobs` directement via `SELECT ... FOR UPDATE SKIP LOCKED`.
- **Stockage** : Postgres unique avec extensions TimescaleDB (timeseries de scan), pgvector (index sémantique) et Apache AGE (graphe d'actifs). **Pas de stockage objet** : les exports / artefacts vivent en filesystem local (volume monté) ou comme blobs Postgres. Pas de S3, pas de MinIO en v1.
- **Embeddings** : interface `Embedder` pluggable, **sélection par variable d'environnement**. Implémentations livrées : (a) modèle local in-process (défaut, zéro appel sortant) ; (b) **Ollama** (sidecar local, parle un endpoint REST sur `localhost`/réseau privé — recommandé pour les opérateurs qui veulent isoler le runtime LLM mais rester self-hosted) ; (c) `mistral-embed` (API EU) optionnel ; (d) OpenAI-compatible générique optionnel (couvre par extension tout endpoint qui parle l'API OpenAI). Le modèle concret pour les providers locaux/Ollama est lui aussi configurable par env.
- **Auth** : **local-first**. Auth locale (utilisateur/mot de passe Argon2id + clés API personnelles hashées) toujours disponible et active par défaut, aucun IdP externe requis pour démarrer. **OIDC** (Keycloak, Authentik, Dex, etc.) activable en parallèle par configuration ; les deux mécanismes coexistent. Panne IdP externe ne bloque pas l'instance.
- **MCP** : transport HTTP+SSE uniquement (stdio non livré), intégré au process Rails.
- **Distribution** : images de container OCI multi-arch (amd64, arm64), `docker-compose.yml` de référence, chart Helm, archives source signées par release.

## Modèle de menace et limites de responsabilité

- **L'opérateur est le controller RGPD.** Il déclare la base légale du scan (intérêt légitime sur ses propres actifs, contrat avec le tiers scanné, etc.). Le projet ne valide pas cette base.
- **Reconaut applique le scope.** Le scanner refuse en dur les cibles hors scope. Modifier la liste d'autorisation passe par un workflow auditable.
- **Pas de scan offensif.** Aucun PoC d'exploitation, aucun payload weaponisé, aucune désanonymisation, aucun bruteforce d'authentification.
- **Pas de télémétrie vers un acteur tiers.** L'instance auto-hébergée n'envoie aucune donnée vers le projet ni vers un service tiers. Le code N'EMBARQUE PAS de SDK d'analytics (Mixpanel, Segment, Amplitude, PostHog, etc.) et n'a pas d'endpoint de télémétrie codé en dur vers le projet. **L'instrumentation OpenTelemetry interne (traces / métriques / logs) PEUT être exposée** par le code applicatif pour que l'opérateur la collecte avec son propre stack d'observabilité (Jaeger, Tempo, Prometheus, Loki, Grafana, etc.) — l'opérateur configure le collecteur, pointe vers son endpoint à lui, et reste seul destinataire.

## Gouvernance et distribution

- **Licence** : **AGPL-3.0-only**. Le projet n'a pas de vocation commerciale ; l'AGPL protège contre la ré-hébergement en service managé fermé, ce qui est la seule contrepartie attendue pour le travail open source.
- **Contributions** : DCO (sign-off) plutôt que CLA — pas de cession de droits supplémentaires demandée.
- **Releases** : SemVer, SBOM CycloneDX publié avec chaque image, signatures Sigstore/cosign.
- **Roadmap publique** dans le repo (ce dossier OpenSpec).

## Non-objectifs

- Pas de balayage du grand internet (IPv4/IPv6 publics non autorisés par l'opérateur).
- Pas d'exploitation active, pas de PoC d'exploitation, pas de payloads weaponisés.
- Pas de désanonymisation, pas de scan au-delà de barrières authentifiées.
- Pas de mode multi-tenant ni de support multi-utilisateurs en v1. Un opérateur qui veut isoler plusieurs périmètres ou donner un accès partiel à un agent externe passe par plusieurs instances ou par des clés API à scopes réduits.
- Pas un produit autonome de scan-puis-rapport. Reconaut est un composant de la stack de l'opérateur, intégré via MCP avec ses agents IA et avec d'autres outils (entrée : ingestion de scanners externes ; sortie : MCP, futurs webhooks).
- Pas de stockage objet (S3, MinIO, Azure Blob…) en v1 — filesystem ou Postgres.
- Pas de broker de jobs externe — GoodJob (Postgres) suffit.
- Pas de clients mobiles en v1.

## Conventions OpenSpec utilisées ici

- Les changes vivent sous `openspec/changes/<change-id>/`.
- Les domaines sont scindés en une spec par capacité (`scanning`, `ai-optimization`, `agent-interface`, `mcp-server`, `gdpr-compliance`, `platform`, `open-source-governance`, `architecture`, `graph-retrieval`).
- Chaque `### Requirement:` porte au moins un `#### Scenario:` et utilise MUST/SHALL (DOIT/DEVRA en français).
- Les marqueurs structurels OpenSpec restent en anglais pour compatibilité outillage : `## ADDED Requirements`, `## MODIFIED Requirements`, `## REMOVED Requirements`, `### Requirement:`, `#### Scenario:`, mots Gherkin en gras **GIVEN**/**WHEN**/**THEN**/**AND**. Le contenu en dessous est en français.
