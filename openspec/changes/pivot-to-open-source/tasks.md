# Tâches : pivot-to-open-source

Checklist du pivot vers un projet OSS auto-hébergeable, scope-driven, operator-as-controller. Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Décisions de gouvernance OSS — spec : `open-source-governance`

- [ ] **1.1 Application de la licence AGPL-3.0-only**
  - **Notes** : Décision actée (cf. proposal §Décisions prises §1) — pas de vocation commerciale, AGPL protège contre la ré-hébergement managé fermé sans réciprocité. Intégrer le texte intégral d'AGPL-3.0 dans `LICENSE` à la racine, ajouter `SPDX-License-Identifier: AGPL-3.0-only` en en-tête de chaque fichier source. Rédiger un ADR court `docs/adr/0001-license.md` qui consigne la décision (contexte, options écartées Apache-2.0/BUSL-1.1, conséquences). Vérifier la compatibilité de licence des dépendances (transitives incluses) — refuser toute dépendance dont la licence est incompatible avec AGPL côté sortie.
  - **Test plan** : `licensee detect .` renvoie `AGPL-3.0-only` ; un check CI échoue si un fichier source n'a pas l'en-tête SPDX attendu ; un audit `bundle-audit` / `cargo-deny` / `pnpm licenses ls` confirme zéro dépendance avec licence incompatible.

- [ ] **1.2 Politique de contribution (DCO)**
  - **Notes** : Ajouter `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1), workflow GitHub Action `dco-check` qui rejette les PR sans `Signed-off-by:` valide.
  - **Test plan** : Une PR sans sign-off est rejetée par le check DCO ; une PR avec sign-off passe.

- [ ] **1.3 Politique de télémétrie opt-in**
  - **Notes** : Documenter dans `docs/operating/telemetry.md` : (a) liste exhaustive des champs jamais collectés sans consentement, (b) liste des champs collectés *si* opt-in, (c) endpoint de réception, (d) mécanisme de désactivation après opt-in. Le code DOIT fail closed (rien n'est envoyé tant que l'opérateur n'a pas explicitement coché l'opt-in).
  - **Test plan** : Test d'intégration boote l'instance avec config par défaut → 0 requête sortante vers un endpoint de télémétrie observée. Avec `telemetry.enabled=true` → un payload anonymisé est envoyé au prochain tick.

---

## 2. Distribution et release — spec : `open-source-governance`

- [ ] **2.1 Images OCI multi-arch**
  - **Notes** : Dockerfile par app (api, web, scanner). Build multi-arch (amd64 + arm64) via `docker buildx`. Publication sur GitHub Container Registry (et miroirs si retenu). Tag par version SemVer + tag `latest` flottant.
  - **Test plan** : Workflow CI `release.yml` produit les images ; `docker pull ghcr.io/<org>/reconaut-api:vX.Y.Z` réussit sur les deux architectures ; un test de smoke démarre le container et vérifie que le healthcheck passe.

- [ ] **2.2 SBOM CycloneDX par release**
  - **Notes** : `syft` ou équivalent générant un SBOM par image, attaché à la release GitHub.
  - **Test plan** : Chaque release publiée a un asset `sbom-<image>-vX.Y.Z.cdx.json` ; un check CI échoue si l'asset manque.

- [ ] **2.3 Signatures Sigstore/cosign**
  - **Notes** : Signer les images et les SBOM avec keyless cosign (OIDC GitHub Actions).
  - **Test plan** : `cosign verify --certificate-identity-regexp ...` réussit sur chaque image release ; un script reproductible de vérification est documenté pour les opérateurs.

- [ ] **2.4 Chart Helm et docker-compose de référence**
  - **Notes** : Chart Helm sous `deploy/helm/reconaut` avec valeurs par défaut sécurisées (single-tenant, télémétrie off, embedder local). `docker-compose.yml` à la racine pour le dev local et les déploiements simples.
  - **Test plan** : `helm install reconaut ./deploy/helm/reconaut --dry-run` produit un manifest valide ; `docker compose up -d` démarre la stack et le healthcheck `/healthz` répond 200 en moins de 60 s.

---

## 3. Scope de scan déclaratif — spec : `scanning`

- [ ] **3.1 Modèle de domaine `ScanScope` et table `scan_scope_entries`**
  - **Notes** : Table avec colonnes `id`, `kind` (`cidr` | `domain` | `host`), `value`, `description`, `created_by`, `created_at`, `revoked_at`. Migration et modèle ActiveRecord. Aucune entrée par défaut — l'opérateur déclare son scope explicitement.
  - **Test plan** : `bundle exec rspec spec/models/scan_scope_entry_spec.rb` couvre la validation des trois `kind`, le rejet des CIDR invalides, l'historisation (revoked_at non nul = inactif).

- [ ] **3.2 Garde de scope dans le worker Rust**
  - **Notes** : Avant chaque sonde, le worker vérifie que la cible appartient à au moins une entrée de scope active (résolution DNS pour les `domain` faite au moment du scan). Cible hors scope → job rejeté avec raison `out-of-scope`, ligne d'audit, pas de paquet réseau émis.
  - **Test plan** : Test d'intégration injecte un job pour `203.0.113.5` sans entrée de scope ; assure (a) aucun paquet sortant, (b) statut `out-of-scope` persisté, (c) ligne d'audit. Un job pour `192.0.2.10` avec une entrée de scope `192.0.2.0/24` active passe.

- [ ] **3.3 Workflow d'ajout de scope auditable (UI + API)**
  - **Notes** : Endpoint `POST /scopes` avec body `{ kind, value, description }`. Toute mutation (`POST`, `DELETE`) écrit une ligne d'audit. UI Vue minimale pour lister, ajouter et révoquer.
  - **Test plan** : Test e2e ajoute une entrée via API ; assure (a) entrée présente, (b) ligne d'audit avec `actor`, `action=scope.created`, `target=<id>`, (c) un scan vers cette cible n'est plus rejeté `out-of-scope`.

- [ ] **3.4 Mettre à jour la spec delta `scanning` dans `init-reconaut-platform`**
  - **Notes** : Aligner la PR `init-reconaut-platform` (ou rebaser ce change par-dessus) en supprimant les scenarios qui présupposent du balayage non sollicité (`Scenario: Hôte non répondant reste absent`) et en remplaçant `Asset Discovery Pipeline` par la version scope-driven de ce change. Décision : ce change publie un spec delta `scanning` qui MODIFIE les exigences existantes ; la fusion finale de `init-reconaut-platform` se fait après l'application du présent change.
  - **Test plan** : `openspec validate` passe sur l'arbre `openspec/` après application des deux changes ; revue humaine confirme la cohérence.

---

## 4. Embedder pluggable — spec : `agent-interface`

- [ ] **4.1 Interface `Embedder` formalisée**
  - **Notes** : Module Ruby `Reconaut::Embedder` (interface) avec méthode `embed(texts: Array<String>) -> Array<Array<Float>>`. Trois implémentations livrées : (a) `LocalEmbedder` (modèle ONNX/llama.cpp embarqué — choix concret du modèle différé), (b) `MistralEmbedder`, (c) `OpenAICompatibleEmbedder` générique.
  - **Test plan** : Test contractuel commun aux trois implémentations vérifie : (i) dim de sortie cohérente avec la config, (ii) déterminisme batch vs single-item à epsilon près, (iii) timeout et erreur explicite quand le backend est indisponible. Test additionnel : un mock outbound assure que `LocalEmbedder` n'effectue **aucun appel réseau**.

- [ ] **4.2 Configuration au déploiement**
  - **Notes** : Variable d'environnement / fichier YAML `embedder.provider=local|mistral|openai-compatible`, avec sous-options par provider (URL, clé API, nom de modèle). Défaut : `local`. La config est validée au boot ; un provider mal configuré (clé manquante en `mistral`) fait échouer le boot avec un message clair.
  - **Test plan** : Test paramétré qui boote l'app avec chaque combinaison et assure (a) défaut sans config = `local`, (b) `mistral` sans clé = exit non-zero `embedder-misconfigured`, (c) `openai-compatible` avec URL custom appelle bien cette URL (via mock).

- [ ] **4.3 Mettre à jour la spec delta `agent-interface` dans `init-reconaut-platform`**
  - **Notes** : Ce change publie un delta MODIFIED qui remplace « `mistral-embed` » par « interface `Embedder` » dans les exigences pertinentes ; les scenarios spécifiques à Mistral deviennent conditionnels « *quand* le provider configuré est Mistral ».
  - **Test plan** : `openspec validate` passe.

---

## 5. Mode single-tenant par défaut, multi-tenant opt-in — spec : `platform`

- [ ] **5.1 Flag de déploiement `multi_tenant.enabled`**
  - **Notes** : Quand `false` (défaut), un seul tenant implicite `default` existe ; les UI et API masquent les concepts de tenant ; la RLS est dégénérée à `tenant_id = 'default'`. Quand `true`, le mode multi-tenant complet est activé (RLS, isolation queue, préfixe object store, comme spécifié dans `platform/spec.md`).
  - **Test plan** : Test paramétré boote l'app dans les deux modes ; assure (a) en single-tenant, l'UI ne montre pas de sélecteur de tenant et l'API rejette les body comportant `tenant_id` étranger, (b) en multi-tenant, le test cross-tenant de `init-reconaut-platform/tasks.md` 7.2 passe.

- [ ] **5.2 Authentification locale par utilisateur + clés API personnelles**
  - **Notes** : En plus d'OIDC, livrer une auth locale (`devise` ou équivalent ; mots de passe Argon2id, clés API hashées en base, rotation). C'est le mode par défaut pour les déploiements simples ; OIDC reste activable.
  - **Test plan** : Test e2e crée un compte local, génère une clé API, l'utilise pour appeler l'API et MCP ; assure que la révocation invalide la clé immédiatement.

---

## 6. Conformité RGPD : capacités, pas affirmations — spec : `gdpr-compliance`

- [ ] **6.1 Configuration de résidence par l'opérateur**
  - **Notes** : Variable / config `data_residency.allowed_regions` (liste d'identifiants de région ou simplement une chaîne libre documentaire pour les déploiements hors cloud). Le boot logue la valeur ; aucune valeur EU codée en dur dans le cœur.
  - **Test plan** : Test boote avec `allowed_regions=["self-hosted-rack-1"]` → succès, valeur loguée. Test avec liste vide → exit non-zero `data-residency-not-configured`.

- [ ] **6.2 Workflow d'effacement par sujet (outil opérateur)**
  - **Notes** : UI + API permettant à l'opérateur d'effacer toutes les données liées à un identifiant (IP, domaine, host_id, tenant_id en mode multi-tenant). Effacement transactionnel : OLTP + index vectoriel + graphe AGE + tier froid (si configuré) + tombstone audit. Pas de validation de « contrôle de la cible » : c'est l'opérateur qui décide qui mérite l'effacement, sa propre conformité dicte la procédure interne.
  - **Test plan** : Test e2e crée des données pour un identifiant, exécute l'effacement, assure (a) absence de l'identifiant dans toutes les couches en moins de 1 transaction, (b) tombstone hashée écrite dans le journal d'audit.

- [ ] **6.3 Journal d'audit immuable (capacité, sans exigence de réplication multi-région)**
  - **Notes** : Conserver la table append-only avec rôle Postgres restreint. La réplication cross-région reste *possible* (Postgres standard) mais cesse d'être un invariant cœur ; documenter comment l'activer dans `docs/operating/audit.md`.
  - **Test plan** : `UPDATE`/`DELETE` direct sur la table d'audit échoue avec erreur de permission. Les exigences temporelles « p99 < 5 s » disparaissent du cœur ; la documentation explique comment monitorer le retard de réplication si l'opérateur l'active.

- [ ] **6.4 Retirer le DPA Mistral comme obligation cœur**
  - **Notes** : Le scenario « Mistral comme sous-traitant d'embeddings » devient *conditionnel* : applicable uniquement si l'opérateur active l'embedder Mistral. La doc rappelle que la responsabilité Art. 28 incombe à l'opérateur.
  - **Test plan** : Le spec delta MODIFIED publié dans ce change reformule le scenario en « si l'opérateur active Mistral, alors un DPA Art. 28 entre l'opérateur et Mistral DOIT exister » ; revue humaine confirme.

---

## 7. Documentation publique

- [ ] **7.1 README de projet**
  - **Notes** : Réécrire `README.md` racine : positionnement OSS, mode self-hosted, démarrage rapide (docker-compose), liens vers la doc, badges (license, build, release, SBOM).
  - **Test plan** : Une revue humaine confirme la clarté du quickstart ; un utilisateur externe arrive à lancer une instance locale en suivant uniquement le README.

- [ ] **7.2 Doc opérateur : modèle de responsabilité RGPD**
  - **Notes** : `docs/operating/responsibility-model.md` qui explique : opérateur = controller, Reconaut = outil, fournisseurs externes = subprocessors *de l'opérateur* si activés. Liste des outils que la plateforme fournit pour aider l'opérateur (audit, effacement, configuration de résidence).
  - **Test plan** : La page existe et est référencée depuis le README et la doc d'installation.

- [ ] **7.3 Doc utilisateur : déclaration de scope**
  - **Notes** : `docs/usage/scope.md` qui explique le modèle scope-driven, comment déclarer son scope, ce qui se passe quand une cible est hors scope.
  - **Test plan** : La page existe et est citée depuis l'UI au premier login.

---

## Acceptation pour le change dans son ensemble

- [ ] L'ADR de licence est rédigé et la licence retenue est appliquée au repo.
- [ ] Une instance auto-hébergée démarre via `docker compose up -d` sans aucune clé API externe configurée et reste pleinement fonctionnelle (scan, agent, MCP) avec l'embedder local.
- [ ] Aucun appel sortant n'est observable depuis une instance fraîchement bootée avec config par défaut (vérifié par un test réseau qui audite les sockets ouverts pendant 5 minutes).
- [ ] Le scanner refuse en dur toute cible hors scope déclaré (test rouge avec une cible non-scope, statut `out-of-scope`, zéro paquet réseau).
- [ ] Le mode single-tenant est le défaut ; activer le mode multi-tenant nécessite un flag explicite et fait passer la suite de tests d'isolation déjà écrite dans `init-reconaut-platform/tasks.md` §7.2.
- [ ] Les spec deltas `scanning`, `agent-interface`, `platform`, `mcp-server`, `gdpr-compliance` modifiés par ce change valident sous `openspec validate`.
- [ ] Une release publique a été produite avec image OCI multi-arch signée et SBOM CycloneDX attaché.
