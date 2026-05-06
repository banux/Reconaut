# Reconaut — Contexte projet

Reconaut est un **outil open source auto-hébergeable** d'Attack Surface Management : il scanne le périmètre d'actifs internet **explicitement déclaré par l'opérateur** (CIDR, domaines, hôtes), avec l'IA comme capacité de premier ordre — pas un ajout cosmétique. Pas de balayage du grand internet, pas de collecte de données sur des tiers non consentants : l'opérateur ne scanne que ce qu'il possède ou contrôle.

## Positionnement

- **Open source, auto-hébergeable.** Reconaut est conçu pour tourner chez l'opérateur (équipe sécurité interne, MSSP, SOC, indépendant). Pas de SaaS multi-tenant obligatoire. Une instance peut être single-tenant (cas par défaut, simple) ou multi-tenant (mode opt-in pour MSSP / hébergeur).
- **Scope-driven.** Le scanner refuse par construction de scanner une cible hors de la liste d'autorisation déclarée par l'opérateur. Pas de découverte du grand internet « à la Shodan ».
- **Boundary RGPD claire.** L'opérateur est le responsable de traitement (controller). Reconaut fournit les outils pour qu'il tienne ses obligations (journal d'audit, effacement, résidence configurable), mais ne porte pas la responsabilité de conformité à sa place.

## Différenciateurs

- **Optimisation des scans pilotée par IA** — planification adaptative pondérée par taux de churn, criticité déclarée par l'opérateur et fraîcheur ; détection d'anomalies sur les profils de services par hôte.
- **Interface agent conversationnelle** — recherche en langage naturel sur le jeu de données indexé, propulsée par une couche d'embeddings **pluggable** (défaut self-hostable ; Mistral / OpenAI-compatible disponible si l'opérateur le configure).
- **Serveur MCP** — expose des outils de scan, de recherche et de reporting pour que les agents IA de l'opérateur automatisent les workflows ASM.
- **Auto-hébergement sans condition.** Aucune fonctionnalité critique du produit ne dépend d'un service propriétaire externe. Tout ce qui est externe (LLM, IdP, broker) est substituable et l'opérateur peut tourner 100 % en réseau privé.

## Stack

- **Frontend** : Vue.js 3 (Composition API), Vite.
- **Backend applicatif** : Ruby on Rails monolithe — héberge l'API, l'agent conversationnel, le journal d'audit et le serveur MCP HTTP+SSE dans le même process.
- **Workers de scan** : Rust, binaires séparés du process Rails. Communication Rails ↔ Rust uniquement via file de jobs.
- **Stockage** : Postgres + extensions TimescaleDB (timeseries de scan), pgvector (index sémantique) et Apache AGE (graphe d'actifs) sur un seul cluster. Stockage objet S3-compatible optionnel pour le tier froid.
- **Embeddings** : interface `Embedder` pluggable. Implémentations livrées : (a) modèle local self-hostable (défaut, exécuté in-process ou via un sidecar) ; (b) client `mistral-embed` (API EU) optionnel ; (c) client OpenAI-compatible générique optionnel. Le choix se fait au déploiement, pas en dur.
- **Auth** : OIDC (Keycloak, Authentik, Dex, etc.) **ou** authentification locale par utilisateur/mot de passe + clés API personnelles, selon le mode de déploiement. Le choix concret est laissé à l'opérateur.
- **MCP** : transport HTTP+SSE uniquement (stdio non livré), intégré au process Rails.
- **Distribution** : images de container OCI multi-arch (amd64, arm64), `docker-compose.yml` de référence, chart Helm, archives source signées par release.

## Modèle de menace et limites de responsabilité

- **L'opérateur est le controller RGPD.** Il déclare la base légale du scan (intérêt légitime sur ses propres actifs, contrat avec le tiers scanné, etc.). Le projet ne valide pas cette base.
- **Reconaut applique le scope.** Le scanner refuse en dur les cibles hors scope. Modifier la liste d'autorisation passe par un workflow auditable.
- **Pas de scan offensif.** Aucun PoC d'exploitation, aucun payload weaponisé, aucune désanonymisation, aucun bruteforce d'authentification.
- **Pas de phone-home.** L'instance auto-hébergée n'envoie aucune donnée vers le projet. Toute télémétrie est strictement opt-in et anonyme.

## Gouvernance et distribution

- **Licence** : à figer dans le change `pivot-to-open-source`. Candidates : AGPL-3.0 (défaut proposé, protège contre la ré-hébergement sans contribution), Apache-2.0 (adoption plus large), BUSL-1.1 (transition source-available → OSS différée). Le choix est une décision explicite documentée dans l'ADR du change.
- **Contributions** : DCO (sign-off) plutôt que CLA, sauf décision contraire.
- **Releases** : SemVer, SBOM CycloneDX publié avec chaque image, signatures Sigstore/cosign.
- **Roadmap publique** dans le repo (ce dossier OpenSpec).

## Non-objectifs

- Pas de balayage du grand internet (IPv4/IPv6 publics non autorisés par l'opérateur).
- Pas d'exploitation active, pas de PoC d'exploitation, pas de payloads weaponisés.
- Pas de désanonymisation, pas de scan au-delà de barrières authentifiées.
- Pas de SaaS multi-tenant obligatoire en cœur de produit (un éventuel hébergement managé serait un déploiement *au-dessus* du même code, pas une variante du cœur).
- Pas de clients mobiles en v1.

## Conventions OpenSpec utilisées ici

- Les changes vivent sous `openspec/changes/<change-id>/`.
- Les domaines sont scindés en une spec par capacité (`scanning`, `ai-optimization`, `agent-interface`, `mcp-server`, `gdpr-compliance`, `platform`, `open-source-governance`, `architecture`, `graph-retrieval`).
- Chaque `### Requirement:` porte au moins un `#### Scenario:` et utilise MUST/SHALL (DOIT/DEVRA en français).
- Les marqueurs structurels OpenSpec restent en anglais pour compatibilité outillage : `## ADDED Requirements`, `## MODIFIED Requirements`, `## REMOVED Requirements`, `### Requirement:`, `#### Scenario:`, mots Gherkin en gras **GIVEN**/**WHEN**/**THEN**/**AND**. Le contenu en dessous est en français.
