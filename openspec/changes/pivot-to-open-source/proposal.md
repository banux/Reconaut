# Change : pivot-to-open-source

## Pourquoi
Le change fondateur `init-reconaut-platform` cadrait Reconaut comme un SaaS multi-tenant européen équivalent de Shodan, scannant le grand internet pour ses tenants payants. La direction du projet a changé : Reconaut devient un **outil open source auto-hébergeable** qui ne scanne **que le périmètre explicitement déclaré par l'opérateur** (CIDR possédés, domaines opérés, hôtes contrôlés). C'est désormais un produit ASM (Attack Surface Management) qu'une équipe sécurité installe chez elle, pas un service hébergé qui crawle l'internet.

Cette pivote retire deux invariants centraux des spec deltas existants :
1. **Balayage du grand internet** — la spec `scanning` actuelle décrit la découverte sur les plages IPv4 publiques et un échantillon IPv6. Ce mode est retiré : sans déclaration de scope par l'opérateur, le scanner ne scanne rien.
2. **Reconaut comme controller RGPD** — la spec `gdpr-compliance` actuelle traite Reconaut comme responsable de traitement vis-à-vis de personnes physiques scannées (DSAR « pour personne physique identifiable dans les données de scan »). Dans le nouveau modèle, l'opérateur est le controller ; Reconaut est un outil qu'il déploie. La plateforme fournit les *capacités* (audit, effacement, résidence configurable) sans porter la *responsabilité* à la place de l'opérateur.

Trois invariants centraux changent de statut **d'obligatoire à optionnel** :
- Multi-tenant — par défaut single-tenant. Un mode multi-tenant reste disponible pour les MSSP / hébergeurs.
- Multi-actif EU avec deux régions read/write — décision de déploiement de l'opérateur, pas un invariant du cœur.
- Mistral comme fournisseur d'embeddings — devient une option parmi plusieurs derrière l'interface `Embedder`. Le défaut livré est self-hostable (pas d'appel sortant obligatoire).

Le change ajoute aussi une nouvelle capacité **`open-source-governance`** qui formalise les obligations propres au statut OSS : licence, artefacts de distribution, télémétrie strictement opt-in, modèle de contribution, SBOM par release.

## Ce qui change

1. **`scanning`** — *MODIFIED* : la découverte d'actifs n'opère que sur le scope déclaré ; les sondes hors scope sont refusées en dur. *REMOVED* : le scenario « hôte non répondant reste absent » (sur balayage de `/24`) car il suppose un balayage non sollicité. *ADDED* : workflow de déclaration et de validation du scope.
2. **`gdpr-compliance`** — *MODIFIED* : la résidence devient une politique de déploiement configurable (l'opérateur déclare sa zone de résidence ; la plateforme l'applique mais ne fige plus l'EU comme seule possibilité). Le DPA Art. 28 avec Mistral devient une obligation conditionnelle (uniquement si l'opérateur active l'embedder Mistral). *REMOVED* : le workflow DSAR « pour personne physique scannée tierce » n'est plus le cas d'usage central — il ne s'applique plus puisque l'opérateur ne scanne que son propre périmètre. *ADDED* : workflow d'export et d'effacement par sujet, à la main de l'opérateur, qui devient la base concrète de sa propre conformité.
3. **`agent-interface`** — *MODIFIED* : l'agent dépend d'une interface `Embedder` pluggable, **pas** spécifiquement de Mistral. Le défaut livré est un modèle local self-hostable. La résilience face à un fournisseur externe reste exigée *quand* un fournisseur externe est configuré.
4. **`platform`** — *MODIFIED* : multi-tenant devient un mode opt-in. *REMOVED* : la facturation Stripe disparaît du cœur (un éventuel offre managée serait un déploiement séparé, hors scope du projet OSS). L'authentification OIDC reste supportée mais une authentification locale (utilisateurs + clés API) est aussi un mode valide pour les déploiements simples.
5. **`mcp-server`** — *MODIFIED* : les clés API sont scope-limitées par utilisateur ou par tenant selon le mode du déploiement. Le contrat HTTP+SSE inchangé.
6. **`open-source-governance`** — *ADDED* (nouvelle capacité) : licence, artefacts de distribution OCI/Helm, SBOM par release, télémétrie opt-in stricte, DCO sign-off, signatures de release.

`openspec/project.md` est entièrement réécrit pour refléter le nouveau positionnement (auto-hébergeable, scope-driven, operator-as-controller).

Les changes `add-tech-stack` (Vue/Rails/Rust) et `add-graph-retrieval` (Apache AGE) restent valides et compatibles avec ce pivot — leur stack et leur design fonctionnent à l'identique en mode self-hosted.

## Contraintes
- **Aucune dépendance critique propriétaire ou hébergée non substituable.** Toute fonctionnalité essentielle DOIT pouvoir tourner en réseau privé sans appel sortant. Tout ce qui sort vers internet (Mistral, OIDC public, etc.) DOIT être désactivable.
- **Scope as code.** La liste d'autorisation de scan DOIT être déclarée explicitement (fichier de configuration versionné, ou table déclarée via UI/API avec audit). Le scanner refuse toute cible non couverte par une entrée de scope active. Pas d'override implicite.
- **Operator-as-controller.** La doc et les UI DOIVENT exposer clairement que l'opérateur est responsable de traitement. Reconaut ne fait aucune affirmation de conformité « par défaut » qui dépasserait la fourniture des outils techniques.
- **Telemetry opt-in stricte.** Aucune donnée NE DOIT quitter l'instance auto-hébergée sans consentement explicite et opt-in de l'opérateur. Désactivé par défaut. Métriques, crash reports, statistiques d'usage : tout est opt-in.
- **Reproducibilité.** Les images de container DOIVENT être reproductibles, signées, et accompagnées d'un SBOM par release.
- **Pas de feature gate propriétaire.** Aucune fonctionnalité du cœur ne peut être verrouillée derrière un commit de licence ou un build « enterprise ». Si un mode managé est proposé un jour, il vit *au-dessus* du même code, sans fork de fonctionnalités cœur.

## Non-objectifs (hors scope de ce change)
- **Choix de la licence concrète.** Le change pose les exigences (licence OSI-approved, distribution sans signature CLA, etc.) ; le choix exact (AGPL-3.0 vs Apache-2.0 vs autre) est une décision à prendre dans la tâche `1.1` avec un ADR dédié. Le change ne tranche pas pour ne pas bloquer la révision spec sur un débat licence.
- **Mode multi-tenant détaillé.** L'exigence retient « multi-tenant possible quand activé » ; les détails (provisioning de tenant, quota, billing externe) feront l'objet d'un change ultérieur si la communauté/l'équipe le demandent.
- **Marketplace ou écosystème de plugins de sondeurs.** Hors scope ; la stack actuelle (workers Rust + contrat de message versionné) n'interdit pas son apparition future.
- **Migration depuis un déploiement SaaS antérieur.** Il n'y a pas eu de SaaS livré ; aucun chemin de migration à prévoir.
- **Build « managed/enterprise » fermé.** Délibérément exclu : le code cœur reste OSS sans variantes verrouillées.

## Décisions prises
1. **Scope-driven scanning** — Le scanner refuse en dur les cibles hors scope déclaré par l'opérateur. C'est la frontière éthique et légale du produit. Conséquence : la spec `scanning` ne décrit plus de découverte sur le grand internet.
2. **Operator-as-controller RGPD** — Reconaut fournit les outils (audit immuable, effacement, configuration de résidence) ; l'opérateur porte la responsabilité de conformité. Conséquence : la spec `gdpr-compliance` devient « *capacités* de conformité » plutôt que « affirmations de conformité ».
3. **Embedder pluggable, défaut self-hostable** — L'instance auto-hébergée DOIT pouvoir tourner sans appel sortant. Mistral, OpenAI-compatible et tout autre fournisseur restent des options derrière l'interface `Embedder`.
4. **Multi-tenant optionnel** — Single-tenant par défaut, multi-tenant en mode opt-in. Cela simplifie radicalement le déploiement le plus courant (équipe sécurité interne) tout en préservant le cas MSSP.
5. **Télémétrie strictement opt-in** — Pas de phone-home par défaut. Toute donnée envoyée vers le projet exige un consentement explicite et est anonymisée.
6. **DCO sign-off, pas CLA** — Friction d'entrée minimale pour les contributeurs ; pas de cession de droits supplémentaires demandée.

## Différé (non bloquant, parqué pour plus tard)
- **Choix de licence concret** (AGPL-3.0 vs Apache-2.0 vs BUSL-1.1) — à trancher en task 1.1 par ADR. Décision blocante pour la première release publique mais pas pour la révision de ce change.
- **Mode multi-tenant détaillé** — provisioning, quota, RBAC étendu — à formaliser dans un change `add-multi-tenant-mode` si la demande émerge.
- **Politique de marque / trademark** — à formaliser quand le projet aura un nom et une identité publics stabilisés.
- **Build d'images reproductibles à l'octet** — l'exigence parle de reproductibilité fonctionnelle (même Dockerfile, mêmes lockfiles, mêmes hashes de couches non-builder). La reproductibilité bit-à-bit (timestamps, ordre de fichiers tar) est désirable mais différée.
- **Modèle d'embedding self-hostable concret** — choix entre `bge-small`, `e5-small-v2`, `nomic-embed-text` ou autre — à trancher quand l'implémentation de l'agent atterrit. La spec exige un défaut self-hostable, pas un modèle nommé.
