# Change : init-reconaut-platform

## Pourquoi
Reconaut est initialisé comme un **outil open source auto-hébergeable** d'Attack Surface Management : il scanne le périmètre d'actifs internet **explicitement déclaré par l'opérateur** (CIDR, domaines, hôtes), avec l'IA comme capacité de premier ordre (optimisation, agent conversationnel, automatisation MCP). Pas de balayage du grand internet, pas de SaaS multi-tenant obligatoire, pas de facturation embarquée — l'opérateur tourne une instance chez lui et reste responsable de traitement RGPD vis-à-vis des actifs qu'il scanne.

Ce change établit les exigences fondatrices à travers sept domaines pour que les changes OpenSpec suivants se conçoivent contre une base stable.

C'est volontairement un change de *fondation* : il code la surface contractuelle de la plateforme (ce qu'elle fait, ce qu'elle ne DOIT PAS faire, comment elle est observable) plutôt que d'implémenter une fonctionnalité unique en profondeur. Les fonctionnalités concrètes (par ex. un sondeur de protocole donné, un modèle d'anomalie particulier) feront l'objet de propositions OpenSpec ultérieures.

## Ce qui change
Le change ajoute des exigences initiales dans sept domaines de spec :

1. **scanning** — pipeline scope-driven (refus en dur des cibles hors scope déclaré), fingerprinting de ports/services, contrôles d'abus (rate limits, robots.txt), workflow de déclaration de scope auditable, rétention.
2. **ai-optimization** — planificateur adaptatif, détection d'anomalies.
3. **agent-interface** — recherche sémantique via une interface `Embedder` pluggable (défaut self-hostable, sans appel sortant ; Mistral / OpenAI-compatible activables par configuration), restriction au tenant (en mode multi-tenant), citation de provenance, résilience face aux pannes du fournisseur externe quand activé.
4. **mcp-server** — surface d'outils MCP (`search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report`), scopes, audit. Transport HTTP+SSE uniquement. TLS exigé en exposition publique, configurable selon la posture de déploiement (déploiement strictement interne avec mTLS au reverse proxy reste valide).
5. **gdpr-compliance** — résidence configurable par l'opérateur (la plateforme ne fige plus l'EU comme seule possibilité), workflow d'effacement par identifiant comme outil opérateur (l'opérateur est le controller), journal d'audit immuable.
6. **platform** — single-tenant par défaut, mode multi-tenant opt-in pour MSSP/hébergeurs ; isolation par RLS Postgres + partitionnement queue + préfixe object store quand activé ; OIDC ou auth locale (utilisateurs + clés API), au choix de l'opérateur.
7. **open-source-governance** — licence AGPL-3.0-only, distribution OCI multi-arch + SBOM CycloneDX + signatures cosign, télémétrie strictement opt-in fail-closed, DCO sign-off (pas de CLA), aucune dépendance externe critique non-substituable, support du déploiement air-gapped.

Il amorce aussi `openspec/project.md` pour que les changes futurs partagent un document de contexte.

## Contraintes
- **Scope as code.** Le scanner refuse en dur les cibles hors scope déclaré par l'opérateur. Le scope est une liste d'entrées typées (`cidr`, `domain`, `host`) avec audit des mutations. Pas d'override implicite.
- **Operator-as-controller RGPD.** L'opérateur déclare la base légale de ses scans et porte la responsabilité de conformité. Reconaut fournit les *capacités* (audit, effacement transactionnel, résidence configurable) sans porter la responsabilité à la place de l'opérateur.
- **Aucune dépendance externe critique non-substituable.** Toute fonctionnalité essentielle DOIT pouvoir tourner en réseau privé sans appel sortant. Tout ce qui sort vers internet (embedder externe, OIDC public, etc.) DOIT être désactivable et désactivé par défaut.
- **Pas de facturation, pas de métering commercial.** Aucune intégration de billing (Stripe ou autre) n'est embarquée dans le cœur. Les compteurs `scans_total`, `mcp_calls_total` etc. restent exposés comme métriques Prometheus pour observabilité, pas comme inputs de facturation.
- **Télémétrie strictement opt-in fail-closed.** Aucune donnée NE DOIT quitter l'instance auto-hébergée sans consentement explicite. Désactivée par défaut.
- **Isolation tenant à la couche la plus basse possible** (RLS Postgres, partitionnement de queue, préfixe object store) quand le mode multi-tenant est activé — pas par filtres applicatifs après-coup.

## Non-objectifs (hors scope de ce change)
- **Balayage du grand internet** (IPv4/IPv6 publics non autorisés par l'opérateur) — exclu par construction.
- **Exploitation active**, PoC d'exploitation ou payloads weaponisés de toute nature.
- **Désanonymisation de masse**, scan au-delà de barrières authentifiées sans autorisation.
- **Clients mobiles** en v1.
- **Distribution SaaS multi-tenant gérée par le projet** — l'OSS est self-hosted ; un éventuel hébergement managé serait un déploiement *au-dessus* du même code, pas une variante du cœur.
- **Facturation, abonnements, métering commercial.** Hors scope définitif.
- **Mode multi-tenant détaillé** (provisioning, quotas, RBAC étendu) — l'exigence retient « possible quand activé » ; les détails feront l'objet d'un change ultérieur si la demande émerge.
- **Build « managed/enterprise » fermé** — délibérément exclu : le code cœur reste OSS sans variantes verrouillées.
- **Choix d'un modèle d'anomalie spécifique** (linéaire / GBDT / NN) — l'exigence spécifie le contrat, pas l'implémentation.
- **Choix du modèle d'embedding local concret** — la spec exige un défaut self-hostable, pas un modèle nommé. Choix entre `bge-small`, `e5-small-v2`, `nomic-embed-text` ou autre, à trancher au moment de l'implémentation.
- **Transport stdio du serveur MCP** — pas en v1.

## Décisions prises
1. **Licence AGPL-3.0-only.** Le projet n'a pas de vocation commerciale. L'AGPL est OSI-approved, accepté par la communauté sécurité (Grafana, Sentry, Plausible, Mautic, Bitwarden), et protège contre la ré-hébergement en service managé fermé sans réciprocité. La friction « certaines boîtes interdisent l'AGPL en interne » est acceptée — un opérateur SOC qui déploie en interne n'est pas affecté par la clause réseau puisqu'il ne distribue pas le service à des tiers.
2. **Scope-driven scanning.** Le scanner refuse en dur les cibles hors scope déclaré. C'est la frontière éthique et légale du produit ; la spec `scanning` ne décrit aucune découverte sur le grand internet.
3. **Operator-as-controller RGPD.** Reconaut fournit les outils ; l'opérateur porte la responsabilité de conformité. La spec `gdpr-compliance` décrit des *capacités*, pas des affirmations.
4. **Embedder pluggable, défaut self-hostable.** L'instance auto-hébergée DOIT pouvoir tourner sans appel sortant. Mistral, OpenAI-compatible et tout autre fournisseur restent des options derrière l'interface `Embedder`.
5. **Multi-tenant optionnel.** Single-tenant par défaut, multi-tenant en mode opt-in. Cela simplifie radicalement le déploiement le plus courant (équipe sécurité interne) tout en préservant le cas MSSP.
6. **Télémétrie strictement opt-in fail-closed.** Pas de phone-home par défaut.
7. **DCO sign-off, pas CLA.** Friction d'entrée minimale pour les contributeurs ; pas de cession de droits supplémentaires demandée.
8. **Pas de facturation dans le cœur.** Aucune intégration commerciale n'est embarquée.
9. **Transport MCP HTTP+SSE uniquement.** Stdio n'est pas livré en v1.

## Différé (non bloquant, parqué pour plus tard)
- **Fournisseur d'identité concret** — Choix entre Keycloak auto-hébergé, Authentik, Dex et al. La spec `platform` exige OIDC + auth locale + les cinq rôles ; l'IdP concret peut être permuté sans altérer le contrat.
- **Modèle d'embedding local concret** — choix entre `bge-small`, `e5-small-v2`, `nomic-embed-text` ou autre. La spec exige un défaut self-hostable et zéro appel sortant ; le modèle nommé sera tranché à l'implémentation.
- **Stockage objet tier froid** — fournisseur S3-compatible. La spec exige un stockage configurable ; le choix est différé et ne bloque pas l'implémentation.
- **Mode multi-tenant détaillé** — provisioning, quotas, RBAC étendu — à formaliser dans un change ultérieur si la demande émerge.
