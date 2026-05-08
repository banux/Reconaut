# Change : init-reconaut-platform

## Pourquoi
Reconaut est initialisé comme un **outil open source auto-hébergeable** d'Attack Surface Management : il scanne le périmètre d'actifs internet **explicitement déclaré par l'opérateur** (CIDR, domaines, hôtes), avec l'IA comme capacité de premier ordre (optimisation, agent conversationnel, automatisation MCP). Pas de balayage du grand internet, **tenant unique** (une instance = un opérateur = un périmètre), pas de facturation embarquée — l'opérateur tourne une instance chez lui et reste responsable de traitement RGPD vis-à-vis des actifs qu'il scanne.

Ce change établit les exigences fondatrices à travers sept domaines pour que les changes OpenSpec suivants se conçoivent contre une base stable.

C'est volontairement un change de *fondation* : il code la surface contractuelle de la plateforme (ce qu'elle fait, ce qu'elle ne DOIT PAS faire, comment elle est observable) plutôt que d'implémenter une fonctionnalité unique en profondeur. Les fonctionnalités concrètes (par ex. un sondeur de protocole donné, un modèle d'anomalie particulier) feront l'objet de propositions OpenSpec ultérieures.

## Ce qui change
Le change ajoute des exigences initiales dans sept domaines de spec :

1. **scanning** — pipeline scope-driven (refus en dur des cibles hors scope déclaré), fingerprinting de ports/services, contrôles d'abus (rate limits, robots.txt), workflow de déclaration de scope auditable, rétention.
2. **ai-optimization** — planificateur adaptatif, détection d'anomalies.
3. **agent-interface** — recherche sémantique via une interface `Embedder` pluggable, **sélectionnée par variable d'environnement**. Implémentations : embedder local in-process (défaut, sans appel sortant), **Ollama** (sidecar local), Mistral, OpenAI-compatible générique. Citation de provenance, résilience face aux pannes du fournisseur externe quand activé.
4. **mcp-server** — surface d'outils MCP (`search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report`), scopes, audit. Transport HTTP+SSE uniquement. TLS exigé en exposition publique, configurable selon la posture de déploiement (déploiement strictement interne avec mTLS au reverse proxy reste valide).
5. **gdpr-compliance** — résidence configurable par l'opérateur (la plateforme ne fige plus l'EU comme seule possibilité), workflow d'effacement par identifiant comme outil opérateur (l'opérateur est le controller), journal d'audit immuable.
6. **platform** — modèle de données **tenant unique** (pas de notion de tenant dans le schéma) ; **auth locale (utilisateurs + clés API) par défaut, OIDC activable en parallèle** — l'instance démarre toujours sans dépendance externe d'identité.
7. **open-source-governance** — licence AGPL-3.0-only, distribution OCI multi-arch + SBOM CycloneDX + signatures cosign, **aucune télémétrie embarquée** (pas même opt-in), DCO sign-off (pas de CLA), aucune dépendance externe critique non-substituable, support du déploiement air-gapped.

Il amorce aussi `openspec/project.md` pour que les changes futurs partagent un document de contexte.

## Contraintes
- **Scope as code.** Le scanner refuse en dur les cibles hors scope déclaré par l'opérateur. Le scope est une liste d'entrées typées (`cidr`, `domain`, `host`) avec audit des mutations. Pas d'override implicite.
- **Operator-as-controller RGPD.** L'opérateur déclare la base légale de ses scans et porte la responsabilité de conformité. Reconaut fournit les *capacités* (audit, effacement transactionnel, résidence configurable) sans porter la responsabilité à la place de l'opérateur.
- **Aucune dépendance externe critique non-substituable.** Toute fonctionnalité essentielle DOIT pouvoir tourner en réseau privé sans appel sortant. Tout ce qui sort vers internet (embedder externe, OIDC public, etc.) DOIT être désactivable et désactivé par défaut.
- **Pas de facturation, pas de métering commercial.** Aucune intégration de billing (Stripe ou autre) n'est embarquée dans le cœur. Les compteurs `scans_total`, `mcp_calls_total` etc. restent exposés comme métriques Prometheus pour observabilité, pas comme inputs de facturation.
- **Aucune télémétrie vers un acteur tiers.** Pas de SDK d'analytics tiers (Mixpanel, Segment, Amplitude, PostHog, etc.) ni d'endpoint de télémétrie codé vers le projet. L'instrumentation OpenTelemetry interne (traces / métriques / logs) PEUT être exposée pour que l'opérateur la collecte avec son propre stack d'observabilité — l'endpoint du collecteur OTel est configuré par l'opérateur (variable d'env standard `OTEL_EXPORTER_OTLP_ENDPOINT`), pas par le projet.
- **Pas de stockage objet en v1.** Les exports / artefacts vivent en filesystem local (volume monté) ou comme blobs Postgres. Pas de S3, pas de MinIO, pas d'Azure Blob — pour rester self-hostable sans dépendance d'infra cloud.

## Non-objectifs (hors scope de ce change)
- **Balayage du grand internet** (IPv4/IPv6 publics non autorisés par l'opérateur) — exclu par construction.
- **Exploitation active**, PoC d'exploitation ou payloads weaponisés de toute nature.
- **Désanonymisation de masse**, scan au-delà de barrières authentifiées sans autorisation.
- **Clients mobiles** en v1.
- **Distribution SaaS multi-tenant gérée par le projet** — l'OSS est self-hosted. Un opérateur qui veut isoler plusieurs périmètres déploie plusieurs instances ; toute distribution managée par un tiers est extérieure au projet.
- **Mode multi-tenant en v1** — Reconaut est tenant unique par construction. Aucune colonne `tenant_id`, aucune RLS par tenant. Si un besoin émerge, ce sera l'objet d'un change ultérieur dédié.
- **Facturation, abonnements, métering commercial.** Hors scope définitif.
- **Stockage objet S3-compatible** (S3, MinIO, etc.) — exclu en v1, filesystem local ou Postgres pour les artefacts.
- **Build « managed/enterprise » fermé** — délibérément exclu : le code cœur reste OSS sans variantes verrouillées.
- **Choix d'un modèle d'anomalie spécifique** (linéaire / GBDT / NN) — l'exigence spécifie le contrat, pas l'implémentation.
- **Choix du modèle d'embedding local concret** — la spec exige un défaut self-hostable, pas un modèle nommé. Choix entre `bge-small`, `e5-small-v2`, `nomic-embed-text` ou autre, à trancher au moment de l'implémentation.
- **Transport stdio du serveur MCP** — pas en v1.

## Décisions prises
1. **Licence AGPL-3.0-only.** Le projet n'a pas de vocation commerciale. L'AGPL est OSI-approved, accepté par la communauté sécurité (Grafana, Sentry, Plausible, Mautic, Bitwarden), et protège contre la ré-hébergement en service managé fermé sans réciprocité. La friction « certaines boîtes interdisent l'AGPL en interne » est acceptée — un opérateur SOC qui déploie en interne n'est pas affecté par la clause réseau puisqu'il ne distribue pas le service à des tiers.
2. **Scope-driven scanning.** Le scanner refuse en dur les cibles hors scope déclaré. C'est la frontière éthique et légale du produit ; la spec `scanning` ne décrit aucune découverte sur le grand internet.
3. **Operator-as-controller RGPD.** Reconaut fournit les outils ; l'opérateur porte la responsabilité de conformité. La spec `gdpr-compliance` décrit des *capacités*, pas des affirmations.
4. **Embedder pluggable, défaut self-hostable.** L'instance auto-hébergée DOIT pouvoir tourner sans appel sortant. Mistral, OpenAI-compatible et tout autre fournisseur restent des options derrière l'interface `Embedder`.
5. **Tenant unique en v1.** Une instance Reconaut = un opérateur = un périmètre d'actifs. Pas de multi-tenant, pas de RLS par tenant, pas de notion de tenant dans le schéma. Un opérateur qui veut isoler plusieurs périmètres déploie plusieurs instances. Cette simplicité radicale est le bon trade-off pour un OSS self-hosted ; le multi-tenant peut être réintroduit par un change ultérieur si la demande émerge.
6. **Aucune télémétrie vers un acteur tiers.** Pas de phone-home, pas de SDK d'analytics. L'instrumentation OpenTelemetry interne reste autorisée et utile pour la supervision opérateur — l'opérateur configure son propre collecteur (Jaeger, Tempo, Prometheus, etc.), aucune destination n'est codée par le projet.
7. **DCO sign-off, pas CLA.** Friction d'entrée minimale pour les contributeurs ; pas de cession de droits supplémentaires demandée.
8. **Pas de facturation dans le cœur.** Aucune intégration commerciale n'est embarquée.
9. **Transport MCP HTTP+SSE uniquement.** Stdio n'est pas livré en v1.

## Différé (non bloquant, parqué pour plus tard)
- **Fournisseur d'identité OIDC concret** (utilisé seulement si l'opérateur l'active) — Keycloak auto-hébergé, Authentik, Dex et al. La spec `platform` exige auth locale toujours disponible + OIDC optionnel + les cinq rôles ; l'IdP concret peut être permuté sans altérer le contrat.
- **Modèle d'embedding local concret** — choix entre `bge-small`, `e5-small-v2`, `nomic-embed-text` ou autre. La spec exige un défaut self-hostable et zéro appel sortant ; le modèle nommé sera tranché à l'implémentation.
- **Format de tier froid filesystem** — dump compressé Parquet vs JSONL, structure de répertoires, rotation. À trancher à l'implémentation.
