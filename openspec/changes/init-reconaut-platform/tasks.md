# Tâches : init-reconaut-platform

Checklist fondatrice. Chaque tâche inclut des notes d'implémentation et un test plan qui doit passer avant de cocher la case.

---

## 1. Bootstrap du projet et gouvernance OSS

- [ ] **1.1 Application de la licence AGPL-3.0-only**
  - **Notes** : Décision actée (cf. `proposal.md` §Décisions prises §1) — pas de vocation commerciale, AGPL protège contre la ré-hébergement managé fermé sans réciprocité. Intégrer le texte intégral d'AGPL-3.0 dans `LICENSE` à la racine, ajouter `SPDX-License-Identifier: AGPL-3.0-only` en en-tête de chaque fichier source. Rédiger un ADR court `docs/adr/0001-license.md` qui consigne la décision (contexte, options écartées Apache-2.0/BUSL-1.1, conséquences). Vérifier la compatibilité de licence des dépendances (transitives incluses) — refuser toute dépendance dont la licence est incompatible avec AGPL côté sortie.
  - **Test plan** : `licensee detect .` renvoie `AGPL-3.0-only` ; un check CI échoue si un fichier source n'a pas l'en-tête SPDX attendu ; un audit `bundle-audit` / `cargo-deny` / `pnpm licenses ls` confirme zéro dépendance avec licence incompatible.

- [ ] **1.2 Politique de contribution (DCO + Code of Conduct)**
  - **Notes** : Ajouter `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1), workflow GitHub Action `dco-check` qui rejette les PR sans `Signed-off-by:` valide.
  - **Test plan** : Une PR sans sign-off est rejetée par le check DCO ; une PR avec sign-off passe.

- [ ] **1.3 Politique de télémétrie opt-in fail-closed**
  - **Notes** : Documenter dans `docs/operating/telemetry.md` : (a) liste exhaustive des champs jamais collectés sans consentement, (b) liste des champs collectés *si* opt-in, (c) endpoint de réception, (d) mécanisme de désactivation après opt-in. Le code DOIT fail closed (rien n'est envoyé tant que l'opérateur n'a pas explicitement coché l'opt-in).
  - **Test plan** : Test d'intégration boote l'instance avec config par défaut → 0 requête sortante vers un endpoint de télémétrie observée. Avec `telemetry.enabled=true` → un payload anonymisé est envoyé au prochain tick.

- [ ] **1.4 Layout monorepo**
  - **Notes** : Structure cible (alignée avec `add-tech-stack`) : `apps/api/` (Rails monolithe — API, agent, MCP, audit), `apps/web/` (Vue 3 + Vite), `apps/scanner/` (workers Rust), `packages/job-schema/` (schémas de message versionnés), `Dockerfile` par app, `docker-compose.yml` racine pour le dev local et déploiement simple.
  - **Test plan** : `bin/setup` racine installe Ruby, Node, Rust ; `bin/test` exécute en parallèle `bundle exec rspec`, `pnpm test`, `cargo test` ; chaque suite contient un test smoke qui passe.

- [ ] **1.5 Pipeline CI multi-stack (GitHub Actions)**
  - **Notes** : Jobs séparés par app : `api-rubocop`, `api-rspec`, `web-eslint`, `web-vitest`, `scanner-clippy`, `scanner-cargo-test`, build d'image par app. Cache des dépendances (Bundler, pnpm, cargo) keyé par lockfile.
  - **Test plan** : Ouvrir une PR triviale, tous les jobs verts ; introduire une violation volontaire (lint, type) et vérifier que le job correspondant échoue.

---

## 2. Capacité de scan — spec : `scanning`

- [ ] **2.1 Modèle de domaine et stockage time-partitionné**
  - **Notes** : Modèles `Host`, `Service`, `Scan`, `ScanScopeEntry` (avec colonnes `id`, `kind` ∈ `{cidr, domain, host}`, `value`, `description`, `created_by`, `created_at`, `revoked_at`). Hypertable TimescaleDB sur `services(scanned_at)` avec chunks journaliers ; pg_partman pour la rétention.
  - **Test plan** : `bundle exec rspec spec/models/scan_scope_entry_spec.rb` couvre la validation des trois `kind`, le rejet des CIDR invalides, l'historisation. `spec/models/host_spec.rb` assure que l'hypertable est créée et qu'une politique de rétention 90 jours est attachée.

- [ ] **2.2 Garde de scope dans le worker Rust**
  - **Notes** : Avant chaque sonde, le worker vérifie que la cible appartient à au moins une entrée de scope active (résolution DNS pour les `domain` faite au moment du scan). Cible hors scope → job rejeté avec raison `out-of-scope`, ligne d'audit, pas de paquet réseau émis.
  - **Test plan** : Test d'intégration injecte un job pour `203.0.113.5` sans entrée de scope ; assure (a) aucun paquet sortant, (b) statut `out-of-scope` persisté, (c) ligne d'audit. Un job pour `192.0.2.10` avec une entrée de scope `192.0.2.0/24` active passe.

- [ ] **2.3 Worker scanner async avec rate limiting**
  - **Notes** : Token-bucket par cible et par AS ; registry de sondeurs pluggable. Mesure NIC d'egress via wrapper autour du dispatcher.
  - **Test plan** : Lever une cible mock locale sur `127.0.0.1` (dans le scope), lancer un scan de 30 secondes contre un AS limité à 50 rps, assurer que le débit mesuré ∈ [0, 55] rps.

- [ ] **2.4 Workflow d'ajout / révocation de scope auditable**
  - **Notes** : Endpoints `POST /scopes`, `DELETE /scopes/{id}`. Toute mutation écrit une ligne d'audit. UI Vue minimale pour lister, ajouter et révoquer.
  - **Test plan** : Test e2e ajoute une entrée via API ; assure (a) entrée présente, (b) ligne d'audit avec `actor`, `action=scope.created`, `target=<id>`, (c) un scan vers cette cible n'est plus rejeté `out-of-scope`. Révocation : un scan ultérieur est de nouveau rejeté.

- [ ] **2.5 Sondeurs de protocole : HTTP(S), SSH, RDP, MQTT, CoAP, Modbus**
  - **Notes** : Chaque sondeur renvoie un `ProbeResult` typé. Cert TLS feuille hashé (SHA-256). Extrait HTML plafonné dur à 32 KiB. SSH ne capture que la bannière + fp host-key ; jamais d'authentification.
  - **Test plan** : Replay d'un corpus de réponses embarqué pour chaque protocole ; assurer que les champs parsés matchent les snapshots golden au byte près.

- [ ] **2.6 Moteur de rétention**
  - **Notes** : Job nocturne : migration chaud→froid à 90 jours (défaut), surcharge opérateur honorée. Tier froid sur stockage objet S3-compatible (fournisseur configurable, MinIO local par défaut pour dev).
  - **Test plan** : Test d'intégration qui sème des lignes vieilles de >90 jours, lance le job, assure que les lignes sont présentes dans le préfixe froid et absentes de la table chaude ; avec surcharge `hot_days=365`, les mêmes lignes restent en chaud.

---

## 3. Optimisation IA — spec : `ai-optimization`

- [ ] **3.1 Métrique de churn par cible**
  - **Notes** : Vue matérialisée `target_churn_7d` rafraîchie toutes les 15 min.
  - **Test plan** : Semer des historiques synthétiques avec des taux de churn connus ; assurer que les valeurs de la vue matchent à 0,01 près.

- [ ] **3.2 Planificateur adaptatif**
  - **Notes** : Score = `churn × interest × recency_factor`. Scoring linéaire en v1 ; persister entrées de décision et score calculé pour chaque exécution planifiée.
  - **Test plan** : `spec/ai/scheduler_spec.rb` construit une plage à fort churn (>2,0) et une à faible churn (<0,1) à intérêt égal ; assure que la haute-churn est planifiée au moins 4× plus souvent sur une simulation 7 jours.

- [ ] **3.3 Détecteur d'anomalies**
  - **Notes** : Baseline glissant 30 jours par hôte ; flag persisté avec raison ; remonte dans le flux d'anomalies.
  - **Test plan** : Hôte synthétique stable 90 jours, puis injection TCP/22 ; assurer que le flag `new_port:22` apparaît dans le flux en moins de 5 minutes de temps simulé.

---

## 4. Interface agent — spec : `agent-interface`

- [ ] **4.1 Interface `Embedder` formalisée**
  - **Notes** : Module Ruby `Reconaut::Embedder` (interface) avec méthode `embed(texts: Array<String>) -> Array<Array<Float>>`. Trois implémentations livrées : (a) `LocalEmbedder` (modèle ONNX/llama.cpp embarqué — choix concret du modèle différé), (b) `MistralEmbedder`, (c) `OpenAICompatibleEmbedder` générique.
  - **Test plan** : Test contractuel commun aux trois implémentations vérifie : (i) dim de sortie cohérente avec la config, (ii) déterminisme batch vs single-item à epsilon près, (iii) timeout et erreur explicite quand le backend est indisponible. Test additionnel : un mock outbound assure que `LocalEmbedder` n'effectue **aucun appel réseau**.

- [ ] **4.2 Configuration au déploiement**
  - **Notes** : Variable d'environnement / fichier YAML `embedder.provider=local|mistral|openai-compatible`, avec sous-options par provider. Défaut : `local`. La config est validée au boot ; un provider mal configuré (clé manquante en `mistral`) fait échouer le boot avec un message clair.
  - **Test plan** : Test paramétré qui boote l'app avec chaque combinaison et assure (a) défaut sans config = `local`, (b) `mistral` sans clé = exit non-zero `embedder-misconfigured`, (c) `openai-compatible` avec URL custom appelle bien cette URL (via mock).

- [ ] **4.3 Vector store avec filtre tenant poussé dans la requête**
  - **Notes** : pgvector avec index HNSW. Le SQL de retrieval applique `WHERE tenant_id = ...` directement (en mode single-tenant : `tenant_id = 'default'` ; en mode multi-tenant : `tenant_id IN (:caller, 'public')`). Jamais en post-filtre Ruby.
  - **Test plan** : (single-tenant) inspecter le SQL généré et vérifier la présence du filtre. (multi-tenant) lancer 100 requêtes randomisées du tenant A contre un corpus mêlant tenants A, B, public ; assurer qu'aucun résultat ne référence un enregistrement privé du tenant B.

- [ ] **4.4 Endpoint chat `POST /agent/chat`**
  - **Notes** : Streaming SSE via `ActionController::Live`. Chaque item de résultat porte la citation `(host_id, scanned_at)`. Résultats vides renvoient un message explicite « pas de match ».
  - **Test plan** : e2e avec un index fixture contenant des hôtes FR-Modbus et FR-non-Modbus ; requête « modbus exposés en France » ; assurer (a) chaque résultat a country=FR et un service modbus, (b) tous les résultats portent une citation, (c) P95 chemin chaud < 2,5 s sur 50 requêtes échantillons (avec embedder local).

- [ ] **4.5 Résilience embedder externe (conditionnel)**
  - **Notes** : Quand un embedder externe est configuré : timeout par appel à 2,5 s ; circuit breaker (gem `circuit_box` ou équivalent) avec seuils par défaut N=5 échecs / 30 s, ouvert pendant 60 s. Métriques Prometheus `embedding_provider_failures_total`, `embedding_provider_latency_seconds`. Quand le provider est down, l'agent renvoie 503 plutôt qu'un fallback fabriqué.
  - **Test plan** : Test qui configure `embedder.provider=mistral`, simule des 5xx via mock et assure (a) HTTP 503 renvoyé avec body `{"error":"embedding_provider_unavailable","provider":"mistral"}`, (b) compteur de failures incrémenté, (c) circuit breaker s'ouvre après N échecs et rejette les appels suivants immédiatement, (d) timeout de 2,5 s coupe les requêtes longues sans laisser de tâches en arrière-plan.

---

## 5. Serveur MCP — spec : `mcp-server`

- [ ] **5.1 Engine Rails dédié au MCP partageant la pile de middlewares (HTTP+SSE uniquement)**
  - **Notes** : Implémenter `apps/api/engines/mcp` (Rails Engine ou namespace de routes). Outils `search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report` comme controllers Rails. Streaming SSE via `ActionController::Live`. Auth par clé API tenant partagée avec l'API REST. **Pas de chemin de code stdio**.
  - **Test plan** : `spec/mcp/tools_spec.rb` exerce chaque outil sur un transport HTTP+SSE in-process, assurant que la réponse matche le schema JSON déclaré. Test additionnel qui assure qu'aucun binaire de la plateforme n'expose un point d'entrée stdio MCP (`grep`/scan d'imports).

- [ ] **5.2 `request_scan` rejette les cibles hors scope**
  - **Notes** : L'outil valide les paramètres, vérifie le scope (réutilise la même garde que le worker Rust), écrit une ligne d'audit et publie un message `ScanJobV1` sur la file. Renvoie immédiatement le `scan_id` ou erreur structurée `out-of-scope`.
  - **Test plan** : Test d'intégration appelle `request_scan` avec une cible dans le scope ; assure (a) `scan_id` renvoyé en < 100 ms, (b) message publié sur le `JobBus` in-memory. Test négatif : cible hors scope → erreur `out-of-scope`, aucun message publié, ligne d'audit.

- [ ] **5.3 Application des scopes**
  - **Notes** : Table de scopes par clé API (au moins `read:hosts`, `write:scans`, `read:reports`, `manage:scopes`) ; middleware rejette avec erreur MCP structurée contenant le nom du scope manquant.
  - **Test plan** : Clé read-only appelant `request_scan` renvoie `unauthorized` nommant `write:scans` ; la même clé appelant `search_hosts` réussit.

- [ ] **5.4 Audit des appels d'outils**
  - **Notes** : Table d'audit append-only ; ligne écrite en moins de 1 s pour chaque appel d'outil.
  - **Test plan** : Test d'intégration invoque chaque outil une fois et assure qu'une ligne d'audit correspondante existe en moins de 1 s avec `key_id`, `tool_name`, `duration_ms`.

- [ ] **5.5 TLS configurable selon la posture**
  - **Notes** : `mcp.tls.required=true` (défaut) refuse les connexions en clair. `mcp.tls.required=false` (déploiement strictement interne avec mTLS au reverse proxy) accepte les connexions amont en clair ; le boot logue cette posture.
  - **Test plan** : Avec `tls.required=true` : tentative HTTP en clair refusée avec raison `tls-required` ; HTTPS valide réussit. Avec `tls.required=false` : tentative HTTP en clair acceptée et le log de boot mentionne `mcp.tls.required=false posture=internal`.

---

## 6. Conformité RGPD — spec : `gdpr-compliance`

- [ ] **6.1 Configuration de résidence par l'opérateur**
  - **Notes** : Variable / config `data_residency.allowed_regions` (liste d'identifiants de région ou simplement une chaîne libre documentaire pour les déploiements hors cloud). Le boot logue la valeur ; aucune valeur EU codée en dur dans le cœur.
  - **Test plan** : Test boote avec `allowed_regions=["self-hosted-rack-1"]` → succès, valeur loguée. Test avec liste vide → exit non-zero `data-residency-not-configured`. Test Terraform avec une réplication source EU → destination hors-liste rejeté à `terraform plan`.

- [ ] **6.2 Workflow d'effacement par sujet (outil opérateur)**
  - **Notes** : UI + API permettant à l'opérateur d'effacer toutes les données liées à un identifiant (IP, domaine, host_id, tenant_id en mode multi-tenant). Effacement transactionnel : OLTP + index vectoriel + tier froid (si configuré) + tombstone audit. Pas de validation de « contrôle de la cible » : c'est l'opérateur qui décide qui mérite l'effacement, sa propre conformité dicte la procédure interne.
  - **Test plan** : Test e2e crée des données pour un identifiant, exécute l'effacement, assure (a) absence de l'identifiant dans toutes les couches en moins de 1 transaction, (b) tombstone hashée écrite dans le journal d'audit.

- [ ] **6.3 Journal d'audit append-only**
  - **Notes** : Table Postgres avec UPDATE/DELETE révoqués pour le rôle applicatif. Réplication cross-région reste *possible* (Postgres standard) mais cesse d'être un invariant cœur ; documenter comment l'activer dans `docs/operating/audit.md`.
  - **Test plan** : `UPDATE`/`DELETE` direct sur la table d'audit échoue avec erreur de permission et la tentative est elle-même journalisée. Le job de checksum tourne et vérifie le snapshot de la veille.

---

## 7. Plateforme — spec : `platform`

- [ ] **7.1 Flag de déploiement `multi_tenant.enabled`**
  - **Notes** : Quand `false` (défaut), un seul tenant implicite `default` existe ; les UI et API masquent les concepts de tenant ; la RLS est dégénérée à `tenant_id = 'default'`. Quand `true`, le mode multi-tenant complet est activé (RLS, isolation queue, préfixe object store).
  - **Test plan** : Test paramétré boote l'app dans les deux modes ; assure (a) en single-tenant, l'UI ne montre pas de sélecteur de tenant et l'API rejette les body comportant `tenant_id` étranger, (b) en multi-tenant, sonde cross-tenant (1000 appels) renvoie 404 pour IDs existants-d'autre-tenant et IDs inexistants ; variance de timing < 10 ms.

- [ ] **7.2 Authentification : OIDC ET auth locale**
  - **Notes** : Auth locale (`devise` ou équivalent ; mots de passe Argon2id, clés API hashées en base, rotation) comme défaut. OIDC activable en parallèle. La couche d'auth est codée contre l'interface OIDC standard pour qu'un IdP soit substituable sans changer le code applicatif.
  - **Test plan** : Test e2e crée un compte local, génère une clé API, l'utilise pour appeler l'API et MCP ; assure que la révocation invalide la clé immédiatement. Test additionnel monte un IdP fake conforme OIDC pour vérifier que l'app ne dépend d'aucune extension propriétaire.

- [ ] **7.3 Application des rôles**
  - **Notes** : Rôles `owner`, `admin`, `analyst`, `viewer`, `mcp_client`. Chaque endpoint et chaque outil MCP imposent le rôle requis côté serveur.
  - **Test plan** : Test paramétré par rôle exerce chaque endpoint et assure permis/refusé selon la matrice de rôle.

---

## 8. Distribution OSS — spec : `open-source-governance`

- [ ] **8.1 Images OCI multi-arch**
  - **Notes** : Dockerfile par app (api, web, scanner). Build multi-arch (amd64 + arm64) via `docker buildx`. Publication sur GitHub Container Registry. Tag par version SemVer + tag `latest` flottant.
  - **Test plan** : Workflow CI `release.yml` produit les images ; `docker pull ghcr.io/<org>/reconaut-api:vX.Y.Z` réussit sur les deux architectures ; un test de smoke démarre le container et vérifie que le healthcheck passe.

- [ ] **8.2 SBOM CycloneDX + signatures Sigstore/cosign**
  - **Notes** : `syft` génère un SBOM par image, attaché à la release GitHub. Cosign keyless (OIDC GitHub Actions) signe images et SBOM.
  - **Test plan** : Chaque release publiée a un asset `sbom-<image>-vX.Y.Z.cdx.json` ; `cosign verify --certificate-identity-regexp ...` réussit sur chaque image release ; un check CI échoue si l'asset SBOM ou la signature manquent.

- [ ] **8.3 Chart Helm et docker-compose de référence**
  - **Notes** : Chart Helm sous `deploy/helm/reconaut` avec valeurs par défaut sécurisées (single-tenant, télémétrie off, embedder local). `docker-compose.yml` à la racine pour le dev local et les déploiements simples.
  - **Test plan** : `helm install reconaut ./deploy/helm/reconaut --dry-run` produit un manifest valide ; `docker compose up -d` démarre la stack et le healthcheck `/healthz` répond 200 en moins de 60 s.

- [ ] **8.4 Linter no-billing-no-feature-gate**
  - **Notes** : Script CI rejette tout import de SDK de facturation (`stripe`, `chargebee`, `paddle`, etc.) et tout chemin de code conditionné par une variable de licence (`if ENV["RECONAUT_LICENSE_KEY"]`, etc.).
  - **Test plan** : Le linter passe propre sur HEAD. Test : ajouter `gem "stripe"` au Gemfile → le linter échoue. Test : ajouter `if ENV["RECONAUT_LICENSE_KEY"]` dans un controller → le linter échoue.

- [ ] **8.5 Boot air-gapped vérifié**
  - **Notes** : Test e2e qui démarre la stack en réseau privé (sans gateway internet sortant) avec config par défaut + MinIO local + IdP local. Aucun appel sortant ne doit être tenté pendant un cycle d'usage de référence (ajout de scope, scan, recherche agent, appel MCP).
  - **Test plan** : Test réseau audite les sockets sortants pendant 10 minutes sous trafic synthétique ; assure zéro connexion vers une IP publique.

---

## 9. Documentation

- [ ] **9.1 README de projet**
  - **Notes** : Positionnement OSS, mode self-hosted, démarrage rapide (docker-compose), liens vers la doc, badges (license AGPL-3.0, build, release, SBOM).
  - **Test plan** : Une revue humaine confirme la clarté du quickstart ; un utilisateur externe arrive à lancer une instance locale en suivant uniquement le README.

- [ ] **9.2 Doc opérateur : modèle de responsabilité RGPD**
  - **Notes** : `docs/operating/responsibility-model.md` qui explique : opérateur = controller, Reconaut = outil, fournisseurs externes = subprocessors *de l'opérateur* si activés. Liste des outils que la plateforme fournit pour aider l'opérateur (audit, effacement, configuration de résidence).
  - **Test plan** : La page existe et est référencée depuis le README et la doc d'installation.

- [ ] **9.3 Doc utilisateur : déclaration de scope**
  - **Notes** : `docs/usage/scope.md` qui explique le modèle scope-driven, comment déclarer son scope, ce qui se passe quand une cible est hors scope.
  - **Test plan** : La page existe et est citée depuis l'UI au premier login.

- [ ] **9.4 Site de doc public (Docusaurus ou MkDocs)** — référence API + référence outils MCP (HTTP+SSE) + page DSAR opérateur + runbooks de déploiement.

---

## Acceptation pour le change dans son ensemble

- [ ] Chaque exigence des spec deltas (`scanning`, `ai-optimization`, `agent-interface`, `mcp-server`, `gdpr-compliance`, `platform`, `open-source-governance`) a au moins un test automatisé passant en CI.
- [ ] La CI rejette toute fusion qui (a) introduit une dépendance avec licence incompatible AGPL, (b) introduit un import de SDK de facturation, (c) introduit un chemin de code conditionné par une variable de licence commerciale.
- [ ] Une instance auto-hébergée démarre via `docker compose up -d` sans aucune clé API externe configurée et reste pleinement fonctionnelle (scan, agent, MCP) avec l'embedder local.
- [ ] Aucun appel sortant n'est observable depuis une instance fraîchement bootée avec config par défaut (vérifié par un test réseau qui audite les sockets ouverts pendant 10 minutes).
- [ ] Le scanner refuse en dur toute cible hors scope déclaré (test rouge avec une cible non-scope, statut `out-of-scope`, zéro paquet réseau).
- [ ] Le mode single-tenant est le défaut ; activer le mode multi-tenant nécessite un flag explicite et fait passer la suite de tests d'isolation cross-tenant.
- [ ] Une release publique a été produite avec image OCI multi-arch signée et SBOM CycloneDX attaché.
- [ ] Une commande de self-check documentée (`bin/doctor` ou `rails reconaut:doctor`) imprime région, défauts de rétention, fingerprint du modèle d'embedding actif (local ou externe), posture TLS MCP et politiques d'isolation tenant.
