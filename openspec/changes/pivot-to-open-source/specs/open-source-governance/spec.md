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
- **WHEN** le check de licence des dépendances s'exécute (`bundle-audit`, `cargo-deny`, `pnpm licenses`)
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

### Requirement: Telemetry Strictly Opt-In
L'instance auto-hébergée NE DOIT envoyer **aucune** donnée vers un endpoint extérieur tant que l'opérateur n'a pas explicitement activé la télémétrie (config `telemetry.enabled=true` ou case cochée à l'enrôlement). Quand activée, les données collectées DOIVENT être anonymisées (pas de hostname brut, pas d'IP brute, pas de noms de tenants ou d'identifiants utilisateur), exhaustivement documentées, et l'opérateur DOIT pouvoir désactiver la télémétrie à tout moment via un seul changement de config sans redémarrage des autres composants.

#### Scenario: Fail-closed par défaut
- **GIVEN** une instance bootée avec config par défaut (télémétrie désactivée)
- **WHEN** un test d'audit réseau observe les sockets sortants pendant 5 minutes sous trafic simulé
- **THEN** aucune connexion vers un endpoint de télémétrie projet (ou tiers) n'est observée
- **AND** aucun log de type « telemetry payload sent » n'est émis

#### Scenario: Activation explicite et désactivation runtime
- **GIVEN** l'opérateur active `telemetry.enabled=true` et configure un endpoint
- **WHEN** le prochain tick de télémétrie s'exécute
- **THEN** un payload anonymisé conforme au schéma documenté est envoyé à l'endpoint configuré
- **AND** l'opérateur passant à `telemetry.enabled=false` voit la prochaine tentative de tick s'abstenir d'envoyer dans la minute, sans nécessité de redémarrer le service

#### Scenario: Documentation exhaustive
- **GIVEN** la page `docs/operating/telemetry.md`
- **WHEN** un opérateur la lit
- **THEN** elle énumère exhaustivement les champs collectés, leur type, leur fréquence, l'endpoint cible et la politique de rétention
- **AND** un test CI échoue si un nouveau champ est introduit dans le code de télémétrie sans mise à jour de cette page

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
Aucune fonctionnalité du cœur NE DOIT dépendre exclusivement d'un service externe non-substituable. Toute intégration externe (LLM, IdP, broker de jobs, stockage objet, télémétrie) DOIT être (a) substituable par une autre implémentation conforme à une interface documentée, ou (b) optionnelle (désactivable sans perte de fonctionnalité critique). Une instance peut être déployée en environnement *air-gapped* avec uniquement les composants self-hostables livrés.

#### Scenario: Boot air-gapped
- **GIVEN** une instance déployée dans un réseau sans accès internet sortant
- **WHEN** l'opérateur configure : embedder local, auth locale, stockage objet local (MinIO ou équivalent), pas de télémétrie, pas d'OIDC public
- **THEN** l'instance démarre sans erreur, sert l'API, l'agent et MCP
- **AND** aucune tentative de connexion sortante vers un endpoint internet n'est observée pendant un cycle d'usage de référence (scan + recherche agent + appel MCP)
