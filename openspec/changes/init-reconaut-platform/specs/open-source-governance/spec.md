# Spec delta : open-source-governance

## ADDED Requirements

### Requirement: AGPL-3.0-only License
Le code source DOIT être distribué sous **GNU AGPL-3.0-only**, déclarée dans un fichier `LICENSE` à la racine du repo (texte intégral) et reflétée par des en-têtes SPDX (`SPDX-License-Identifier: AGPL-3.0-only`) dans chaque fichier source. Aucune fonctionnalité du cœur NE DOIT être verrouillée derrière une licence commerciale ou un build « enterprise » fermé. Aucune intégration de facturation (Stripe, métering commercial) NE DOIT être embarquée dans le cœur — le projet n'a pas de vocation commerciale, et toute offre managée tierce vivrait *au-dessus* du cœur sans modifier sa licence.

#### Scenario: Fichier LICENSE présent et SPDX cohérent
- **GIVEN** une checkout fraîche du repo
- **WHEN** la suite CI exécute le check de licence
- **THEN** un fichier `LICENSE` racine contient le texte intégral de l'AGPL-3.0
- **AND** chaque fichier source porte un en-tête `SPDX-License-Identifier: AGPL-3.0-only` ; un fichier sans en-tête fait échouer le check
- **AND** `licensee detect .` renvoie `AGPL-3.0-only`

#### Scenario: Dépendances incompatibles refusées
- **GIVEN** une PR qui ajoute une dépendance sous licence incompatible avec AGPL en sortie (par ex. propriétaire fermée, ou clause de non-redistribution)
- **WHEN** le check de licence des dépendances s'exécute (`bundle-audit`, `go-licenses check`, `pnpm licenses`)
- **THEN** le check échoue en nommant la dépendance et la licence incriminée ; la PR ne peut être fusionnée

#### Scenario: Aucune feature gate propriétaire ni intégration de facturation
- **GIVEN** une revue automatisée du code
- **WHEN** un linter scanne (a) les chemins de code conditionnés par une variable de licence (`if ENV["RECONAUT_LICENSE_KEY"]`, etc.), (b) les imports de SDK de facturation (`stripe`, `chargebee`, `paddle`, etc.)
- **THEN** aucun chemin de fonctionnalité ne dépend d'une licence commerciale et aucun SDK de facturation n'est importé ; le linter rejette toute introduction d'un tel chemin ou import

### Requirement: Reproducible Container Distribution
Le projet DOIT publier des images de container OCI multi-arch (au minimum `linux/amd64` et `linux/arm64`) pour chaque application cœur (api, web, scanner) à chaque release SemVer. Les images DOIVENT être construites depuis le repo public via un workflow CI auditable, taguées par version SemVer, accompagnées d'un SBOM CycloneDX et signées via cosign keyless. La reproductibilité fonctionnelle (même Dockerfile + même lockfile = même set de couches non-builder) est exigée ; la reproductibilité bit-à-bit est désirable mais non bloquante.

#### Scenario: Release vX.Y.Z publiée avec image, SBOM, signature
- **GIVEN** un tag SemVer `vX.Y.Z` est poussé
- **WHEN** le workflow `release.yml` s'exécute
- **THEN** pour chaque app cœur (`api`, `web`, `scanner`), une image `ghcr.io/<org>/reconaut-<app>:vX.Y.Z` est publiée pour `amd64` et `arm64`
- **AND** un SBOM CycloneDX `sbom-<app>-vX.Y.Z.cdx.json` est attaché à la release GitHub
- **AND** `cosign verify --certificate-identity-regexp '<workflow GH>' ghcr.io/<org>/reconaut-<app>:vX.Y.Z` réussit
- **AND** un check CI échoue si une release sort sans l'un de ces trois artefacts

#### Scenario: Build reproductible fonctionnel
- **GIVEN** un commit `C` et son lockfile correspondant
- **WHEN** le pipeline build l'image deux fois sur deux runners distincts
- **THEN** les digests des couches non-builder (couches d'application, pas la couche d'OS de base) sont identiques entre les deux builds

### Requirement: No Third-Party Telemetry, Operator-Controlled OpenTelemetry
Le cœur de Reconaut N'EMBARQUE PAS de SDK d'analytics tiers (Mixpanel, Segment, Amplitude, PostHog, Plausible côté serveur, Matomo, etc.) ni d'endpoint de télémétrie codé vers le projet ou un sous-traitant. Aucune donnée NE DOIT être envoyée vers le projet ou un tiers du fait du code livré. **L'instrumentation OpenTelemetry interne** (traces, métriques, logs structurés) DOIT être disponible et activable par l'opérateur, qui DOIT pouvoir pointer le collecteur OTel vers son propre stack d'observabilité (Jaeger, Tempo, Prometheus, Loki, Grafana, etc.) via les variables d'env OpenTelemetry standard (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, etc.). Aucune destination par défaut n'est codée par le projet ; sans configuration explicite, OTel exporte vers `localhost` ou ne pousse nulle part.

#### Scenario: Aucun SDK d'analytics tiers dans le code
- **GIVEN** une revue automatisée du codebase (Rails et Go)
- **WHEN** un linter scanne les imports et les dépendances
- **THEN** aucune gem ni package d'analytics tiers n'est importé (pas de `mixpanel-ruby`, `segment`, `amplitude`, `posthog-ruby`, `matomo`, etc.)
- **AND** aucun endpoint de télémétrie projet n'est codé en dur

#### Scenario: Aucune destination OTel par défaut
- **GIVEN** une instance bootée sans variable `OTEL_EXPORTER_OTLP_ENDPOINT`
- **WHEN** un test d'audit réseau observe les sockets sortants pendant 30 minutes sous trafic synthétique
- **THEN** aucune connexion vers un endpoint OTel public n'est observée
- **AND** aucune connexion vers un endpoint d'analytics tiers n'est observée

#### Scenario: Opérateur active OTel vers son propre collecteur
- **GIVEN** l'opérateur configure `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.internal:4317` dans son environnement de déploiement
- **WHEN** l'instance redémarre et reçoit du trafic
- **THEN** les traces/métriques/logs OTel sont exportés vers cet endpoint
- **AND** aucun export vers une destination autre que celle configurée par l'opérateur n'a lieu

#### Scenario: Métriques Prometheus restent disponibles en pull
- **GIVEN** l'instance déployée
- **WHEN** un opérateur scrape `GET /metrics` depuis son propre Prometheus
- **THEN** les compteurs internes (scans exécutés, requêtes API, durées, etc.) sont disponibles en format Prometheus
- **AND** ces métriques NE SONT PAS poussées par le code Reconaut — c'est l'opérateur qui scrape

### Requirement: Contributor Sign-Off (DCO)
Le projet DOIT exiger un sign-off DCO (Developer Certificate of Origin) sur chaque commit fusionné, vérifié automatiquement par un workflow CI. Le projet NE DOIT PAS exiger de CLA (Contributor License Agreement) qui demanderait une cession de droits supplémentaires aux contributeurs. Le code de conduite (Contributor Covenant 2.1 ou équivalent récent) DOIT être documenté à la racine.

#### Scenario: PR sans sign-off rejetée
- **GIVEN** une PR contenant un commit sans ligne `Signed-off-by: Author <email>`
- **WHEN** le workflow `dco-check` s'exécute
- **THEN** le check échoue et la PR ne peut être fusionnée tant que le sign-off n'est pas ajouté

#### Scenario: PR avec sign-off acceptée
- **GIVEN** une PR dont chaque commit porte un `Signed-off-by:` valide
- **WHEN** `dco-check` s'exécute
- **THEN** le check passe ; la PR peut être fusionnée si les autres checks passent

### Requirement: Public Roadmap and Issue Tracking
La roadmap DOIT être publique dans le repo (sous `openspec/changes/` pour les changes formalisés, ou un document `ROADMAP.md` pour les intentions de plus haut niveau). Les issues, discussions et PRs DOIVENT être ouverts au public sans inscription privilégiée. Les décisions structurantes DOIVENT être tracées par ADR (Architecture Decision Record) sous `docs/adr/`.

#### Scenario: Décision structurante tracée par ADR
- **GIVEN** une décision sur le choix de la licence, du modèle d'embedding local, du broker de jobs, ou de toute autre dimension architecturale
- **WHEN** la décision est prise
- **THEN** un ADR numéroté est ajouté sous `docs/adr/<NNNN>-<slug>.md` avec contexte, options considérées, décision et conséquences
- **AND** le change OpenSpec correspondant référence cet ADR

### Requirement: No Mandatory External Dependency
Aucune fonctionnalité du cœur NE DOIT dépendre exclusivement d'un service externe non-substituable. Toute intégration externe (LLM, IdP) DOIT être (a) substituable par une autre implémentation conforme à une interface documentée, ou (b) optionnelle (désactivable sans perte de fonctionnalité critique). La file de jobs vit dans Postgres (GoodJob), pas dans un broker externe. Le stockage d'artefacts vit en filesystem local ou en Postgres, pas dans un object store. Aucune télémétrie n'est embarquée. Une instance peut être déployée en environnement *air-gapped* avec uniquement les composants self-hostables livrés.

#### Scenario: Boot air-gapped
- **GIVEN** une instance déployée dans un réseau sans accès internet sortant
- **WHEN** l'opérateur configure : embedder local, auth locale, pas d'OIDC public
- **THEN** l'instance démarre sans erreur, sert l'API, l'agent et MCP
- **AND** aucune tentative de connexion sortante vers un endpoint internet n'est observée pendant un cycle d'usage de référence (scan + recherche agent + appel MCP)
- **AND** aucun service externe n'est requis : Postgres tient la file (GoodJob), le filesystem local tient les exports
