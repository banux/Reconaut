# Reconaut — Contexte projet

Reconaut est une **base de connaissance d'actifs internet** open source, auto-hébergeable, **conçue pour les agents IA** : l'opérateur déclare explicitement le périmètre qu'il possède ou contrôle (CIDR, domaines, hôtes) ; Reconaut maintient un **graphe d'actifs scopé** alimenté par scans internes ET ingestion de scanners externes ; et il expose ce graphe via MCP HTTP+SSE pour que des agents IA (Reconaut's own agent + agents externes type Claude / GPT / agents maison) le consomment comme **source faisant autorité** dans leur raisonnement. Pas de balayage du grand internet, pas de collecte de données sur des tiers non consentants.

## Positionnement

- **Base de connaissance pour agents IA.** Reconaut n'est pas un produit autonome de scan-puis-rapport ; c'est un **composant intégrable** dans la stack sécurité de l'opérateur. Le persona principal est l'opérateur qui orchestre des agents IA contre sa surface d'attaque et veut leur donner une source d'autorité partagée.
- **Open source, auto-hébergeable.** Reconaut est une **base de connaissance d'actifs internet** maintenue par son opérateur, queryable par ses agents IA et intégrable à sa stack sécurité. **Mono-user** par construction : une instance = un opérateur = un périmètre d'actifs. Un opérateur qui veut isoler plusieurs périmètres déploie plusieurs instances.
- **Scope-driven.** Le scanner refuse par construction de scanner une cible hors de la liste d'autorisation déclarée par l'opérateur. Pas de découverte du grand internet « à la Shodan ».
- **Données stockées = actifs internet, pas de PII.** Reconaut stocke des entrées de scope (CIDR/domaines/hôtes), des hôtes (IP/FQDN), des services (port/protocole/bannière/fingerprint), des certificats (CN/SAN/hash), et des métadonnées de scan (timestamps, codes de retour). Aucune donnée à caractère personnel n'est requise pour faire fonctionner l'outil. Si l'opérateur ingère involontairement du PII via une bannière ou un finding (rare), c'est à lui d'évaluer ce qu'il en fait — le projet ne fournit pas de framework dédié.

## Différenciateurs

- **Base de connaissance MCP-first pour agents IA** — graphe d'actifs queryable structurellement (Apache AGE) ET sémantiquement (pgvector + embedder pluggable). Le canal canonique de consommation est le serveur MCP HTTP+SSE intégré au process Rails. La TUI `reconautctl`, les agents IA externes et tout client (CI scripts, intégrations) consomment **le même périmètre d'outils MCP** avec la même clé API personnelle. L'API REST se réduit à l'auth bootstrap, au healthcheck et au transport MCP lui-même (cf. change `mcp-as-primary-entrypoint`).
- **Intégration entrante et sortante de première classe.** Entrée : tool MCP `ingest_scan_result` qui accepte des résultats de scanners externes (nmap, OpenVAS, Nuclei, exports Censys/Shodan…) au format `ScanResultV1`, ingérés via la même couche que les workers internes. Sortie : outils MCP de lecture (`search_hosts`, `get_host`, `list_scans`, `export_report`) + futurs webhooks/SIEM. Reconaut est un citoyen de la stack, pas un silo.
- **Optimisation des scans pilotée par IA** — planification adaptative pondérée par taux de churn, criticité déclarée par l'opérateur et fraîcheur ; détection d'anomalies sur les profils de services par hôte.
- **Interface agent conversationnelle** — recherche en langage naturel sur le jeu de données indexé, propulsée par une couche d'embeddings **pluggable** (défaut self-hostable ; Mistral / OpenAI-compatible disponible si l'opérateur le configure).
- **Auto-hébergement sans condition.** Aucune fonctionnalité critique du produit ne dépend d'un service propriétaire externe. Tout ce qui est externe (LLM, IdP) est substituable et l'opérateur peut tourner 100 % en réseau privé.

## Stack

- **Frontend** : binaire Go `reconautctl` (TUI **bubbletea/Charm** sous licence MIT, compatible AGPL). Pas de SPA web, pas de Vue/React/Angular/Svelte/Nuxt en v1 — la TUI est l'interface opérateur unique (cf. change `replace-web-with-tui`). Le binaire consomme MCP HTTP+SSE pour les opérations métier ; seul le login bootstrap parle REST.
- **Workers de scan spécialisés** : un binaire Go par `scan_kind` (`scanner-tcp_probe`, `scanner-tls_capture`, `scanner-http_banner`, `scanner-subdomain_enum`, `scanner-service_fingerprint`, `scanner-dns_records`), chacun consommant sa propre queue GoodJob `scan:<kind>`. La spécialisation réduit la surface d'attaque par binaire et permet de scaler chaque type indépendamment. `scanner-dns_records` (cf. change `add-dns-records-scanner`) résout les enregistrements DNS publics (A, AAAA, MX, NS, TXT, CAA, SOA, CNAME) d'un domaine couvert par le scope — pas d'AXFR.
- **Backend applicatif** : Ruby on Rails 8 (monolithe) — héberge l'API, l'agent conversationnel, le journal d'audit et le serveur MCP HTTP+SSE dans le même process.
- **Workers de scan** : Go (Golang), binaires statiques séparés du process Rails. Communication Rails ↔ Go uniquement via la file de jobs.
- **File de jobs** : **GoodJob** (adapter ActiveJob backé par Postgres, mature et éprouvé en production). Aucun broker externe (pas de Redis / RabbitMQ / NATS / Kafka). Les workers Go consomment la table `good_jobs` directement via `SELECT ... FOR UPDATE SKIP LOCKED`.
- **Stockage** : Postgres unique avec extensions TimescaleDB (timeseries de scan), pgvector (index sémantique) et Apache AGE (graphe d'actifs). **Pas de stockage objet** : les exports / artefacts vivent en filesystem local (volume monté) ou comme blobs Postgres. Pas de S3, pas de MinIO en v1.
- **Embeddings** : interface `Embedder` pluggable, **sélection par variable d'environnement**. Implémentations livrées : (a) modèle local in-process (défaut, zéro appel sortant) ; (b) **Ollama** (sidecar local, parle un endpoint REST sur `localhost`/réseau privé — recommandé pour les opérateurs qui veulent isoler le runtime LLM mais rester self-hosted) ; (c) `mistral-embed` (API EU) optionnel ; (d) OpenAI-compatible générique optionnel (couvre par extension tout endpoint qui parle l'API OpenAI). Le modèle concret pour les providers locaux/Ollama est lui aussi configurable par env.
- **Auth** : **mono-user, local-first** (cf. change `single-user-only`). Une instance = **un seul opérateur humain** identifié par un mot de passe local Argon2id, plus N **clés API personnelles** (hashées en base) que cet opérateur peut générer avec leurs propres scopes MCP (défense-en-profondeur : la TUI prend une clé full-scope ; un agent IA externe peut tourner avec une clé `read:hosts` + `read:scans` uniquement). Pas d'IdP externe en v1, pas de second compte, pas de mécanisme d'invitation. Un opérateur qui veut isoler plusieurs périmètres déploie plusieurs instances Reconaut.
- **MCP** : transport HTTP+SSE uniquement (stdio non livré), intégré au process Rails. **Point d'entrée principal** — la TUI `reconautctl` (cf. `replace-web-with-tui`) consomme MCP pour toutes les opérations métier ; seuls login + génération de clé passent par REST (`/auth/sessions`, `/auth/api_keys`).
- **Distribution** : images de container OCI multi-arch (amd64, arm64), `docker-compose.yml` de référence, chart Helm, archives source signées par release.

## Modèle de menace et limites de responsabilité

- **L'opérateur déclare la base légale et opérationnelle du scan.** Intérêt légitime sur ses propres actifs, autorisation explicite d'un tiers scanné, etc. Le projet ne valide pas cette base — c'est à l'opérateur d'avoir cette discipline avant de pousser une cible dans son scope.
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
- Pas de cadre RGPD applicatif. Reconaut ne traite pas de PII au sens RGPD (cf. Positionnement). Pas de registre des traitements (RoPA), pas de tombstone hashée, pas de validation EU codée en dur. L'audit log et l'effacement par cible existent comme outils opérationnels (forensique, hygiène de la base de connaissance) — pas comme conformité.

## Conventions OpenSpec utilisées ici

- Les changes vivent sous `openspec/changes/<change-id>/`.
- Les domaines sont scindés en une spec par capacité (`scanning`, `ai-optimization`, `agent-interface`, `mcp-server`, `platform`, `open-source-governance`, `architecture`, `graph-retrieval`, `integrations`). La capacité `gdpr-compliance` a été retirée par le change `drop-gdpr-framing` — Reconaut ne stocke pas de PII et n'expose pas de framework de conformité dédié.
- Chaque `### Requirement:` porte au moins un `#### Scenario:` et utilise MUST/SHALL (DOIT/DEVRA en français).
- Les marqueurs structurels OpenSpec restent en anglais pour compatibilité outillage : `## ADDED Requirements`, `## MODIFIED Requirements`, `## REMOVED Requirements`, `### Requirement:`, `#### Scenario:`, mots Gherkin en gras **GIVEN**/**WHEN**/**THEN**/**AND**. Le contenu en dessous est en français.
