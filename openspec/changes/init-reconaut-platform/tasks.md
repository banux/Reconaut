# Tâches : init-reconaut-platform

Checklist fondatrice. Chaque tâche inclut des notes d'implémentation et un test plan qui doit passer avant de cocher la case.

---

## 1. Bootstrap du projet

- [ ] **1.1 Layout monorepo**
  - **Notes** : Créer `apps/api` (FastAPI), `apps/scanner` (workers aiohttp), `apps/agent` (chat + retrieval), `apps/mcp` (serveur MCP), `packages/shared` (modèles DB, types). Python 3.12, workspace `uv`, un Dockerfile par app.
  - **Test plan** : `uv sync && uv run pytest -q` réussit avec un `test_smoke.py` placeholder par app affirmant `True`.

- [ ] **1.2 Pipeline CI (GitHub Actions)**
  - **Notes** : Jobs pour `ruff check`, `mypy --strict`, `pytest`, build de container par app. Cache des venvs uv par hash de `uv.lock`.
  - **Test plan** : Ouvrir une PR triviale, tous les jobs verts ; introduire volontairement une erreur de type et vérifier que le job `mypy` échoue.

---

## 2. Capacité de scan — spec : `scanning`

- [ ] **2.1 Modèles de domaine et stockage time-partitionné**
  - **Notes** : Modèles SQLModel `Host`, `Service`, `Scan`, `OptOutEntry`. Hypertable TimescaleDB sur `services(scanned_at)` avec chunks journaliers ; pg_partman pour la rétention.
  - **Test plan** : `pytest tests/scanning/test_models.py` assure que l'hypertable est créée et qu'une politique de rétention 90 jours est attachée.

- [ ] **2.2 Worker scanner async avec rate limiting**
  - **Notes** : Token-bucket par cible et par AS ; registry de sondeurs pluggable. Mock de la mesure NIC d'egress via wrapper autour du dispatcher.
  - **Test plan** : Lever une cible mock locale sur `127.0.0.1`, lancer un scan de 30 secondes contre un AS limité à 50 rps, assurer que le débit mesuré ∈ [0, 55] rps.

- [ ] **2.3 Résolveur d'opt-out DNS avec cache 30 jours**
  - **Notes** : aiodns pour `_reconaut-optout TXT` ; cache backé par Redis clé domaine apex.
  - **Test plan** : `pytest tests/scanning/test_optout.py` assure (a) sonde ignorée, (b) cache peuplé avec TTL 30 jours, (c) ligne d'audit écrite avec raison `optout-dns`.

- [ ] **2.4 Sondeurs de protocole : HTTP(S), SSH, RDP, MQTT, CoAP, Modbus**
  - **Notes** : Chaque sondeur renvoie un `ProbeResult` typé. Cert TLS feuille hashé (SHA-256). Extrait HTML plafonné dur à 32 KiB. SSH ne capture que la bannière + fp host-key ; jamais d'authentification.
  - **Test plan** : Replay d'un corpus de réponses embarqué pour chaque protocole ; assurer que les champs parsés matchent les snapshots golden au byte près.

- [ ] **2.5 Moteur de rétention**
  - **Notes** : Job nocturne : migration chaud→froid à 90 jours (défaut), surcharge tenant honorée. Tier froid sur stockage objet S3-compatible EU (fournisseur différé).
  - **Test plan** : Test d'intégration qui sème des lignes vieilles de >90 jours, lance le job, assure que les lignes sont présentes dans le préfixe froid et absentes de la table chaude ; avec surcharge tenant `hot_days=365`, les mêmes lignes restent en chaud.

---

## 3. Optimisation IA — spec : `ai-optimization`

- [ ] **3.1 Métrique de churn par cible**
  - **Notes** : Vue matérialisée `target_churn_7d` rafraîchie toutes les 15 min.
  - **Test plan** : Semer des historiques synthétiques avec des taux de churn connus ; assurer que les valeurs de la vue matchent à 0,01 près.

- [ ] **3.2 Planificateur adaptatif**
  - **Notes** : Score = `churn × tenant_interest × recency_factor`. Scoring linéaire en v1 ; persister entrées de décision et score calculé pour chaque exécution planifiée.
  - **Test plan** : `pytest tests/ai/test_scheduler.py` construit une plage à fort churn (>2,0) et une à faible churn (<0,1) à intérêt égal ; assure que la haute-churn est planifiée au moins 4× plus souvent sur une simulation 7 jours.

- [ ] **3.3 Détecteur d'anomalies**
  - **Notes** : Baseline glissant 30 jours par hôte ; flag persisté avec raison ; remonte dans le flux d'anomalies.
  - **Test plan** : Hôte synthétique stable 90 jours, puis injection TCP/22 ; assurer que le flag `new_port:22` apparaît dans le flux tenant en moins de 5 minutes de temps simulé.

---

## 4. Interface agent — spec : `agent-interface`

- [ ] **4.1 Intégration de l'API d'embedding Mistral**
  - **Notes** : Client `mistral-embed` (1024-dim) côté backend. Endpoint EU uniquement ; la clé API tenant Reconaut vit dans le secret manager — jamais en code, image, ou repo. Encapsuler le client derrière une interface `Embedder` (port hexagonal) pour permettre une substitution future sans toucher au reste du code. Cache local par hash de chunk pour éviter les appels redondants. Defaults : `chunk_size=500`, `top_k=5`.
  - **Test plan** : `pytest tests/agent/test_embed.py` (a) avec un mock de l'API Mistral, vérifie la dim de sortie 1024 et le déterminisme batch vs single-item, (b) un test contractuel gated par variable d'environnement `MISTRAL_API_KEY` valide la forme réelle de la réponse contre le sandbox Mistral, (c) un test de cache assure qu'une seconde requête identique ne ré-appelle pas l'API.

- [ ] **4.1bis Résilience et observabilité de l'API d'embedding**
  - **Notes** : Timeout par appel à 2,5 s ; circuit breaker (par ex. `pybreaker`) avec seuils par défaut N=5 échecs / 30 s, ouvert pendant 60 s. Métriques Prometheus `embedding_provider_failures_total`, `embedding_provider_latency_seconds`. Quand l'API est down, l'agent renvoie 503 plutôt qu'un fallback fabriqué.
  - **Test plan** : Test qui simule des 5xx Mistral via mock et assure (a) HTTP 503 renvoyé par l'agent avec body `{"error":"embedding_provider_unavailable"}`, (b) compteur de failures incrémenté, (c) circuit breaker s'ouvre après N échecs et rejette les appels suivants immédiatement, (d) timeout de 2,5 s coupe les requêtes longues sans laisser de tâches en arrière-plan.

- [ ] **4.2 Vector store avec filtre tenant poussé dans la requête**
  - **Notes** : pgvector avec index HNSW. Le SQL de retrieval applique `WHERE tenant_id IN (:caller, 'public')` directement ; jamais en post-filtre Python.
  - **Test plan** : Lancer 100 requêtes randomisées du tenant A contre un corpus mêlant tenants A, B, public ; assurer qu'aucun résultat ne référence un enregistrement privé du tenant B.

- [ ] **4.3 Endpoint chat `POST /agent/chat`**
  - **Notes** : Streaming SSE. Chaque item de résultat porte la citation `(host_id, scanned_at)`. Résultats vides renvoient un message explicite « pas de match ».
  - **Test plan** : e2e avec un index fixture contenant des hôtes FR-Modbus et FR-non-Modbus ; requête « modbus exposés en France » ; assurer (a) chaque résultat a country=FR et un service modbus, (b) tous les résultats portent une citation, (c) P95 chemin chaud < 2,5 s sur 50 requêtes échantillons.

---

## 5. Serveur MCP — spec : `mcp-server`

- [ ] **5.1 Serveur MCP avec les outils requis (HTTP+SSE uniquement)**
  - **Notes** : Utiliser le SDK Python MCP officiel. Implémenter `search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report`. Transport HTTP+SSE uniquement, derrière TLS ; **pas de chemin de code stdio**.
  - **Test plan** : `pytest tests/mcp/test_tools.py` exerce chaque outil sur un transport HTTP+SSE in-process, assurant que la réponse matche le schema JSON déclaré. Test additionnel qui assure qu'aucun binaire de la plateforme n'expose un point d'entrée stdio MCP (`grep`/scan d'imports).

- [ ] **5.2 Application des scopes**
  - **Notes** : Table de scopes par clé API ; middleware rejette avec erreur MCP structurée contenant le nom du scope manquant.
  - **Test plan** : Clé read-only appelant `request_scan` renvoie `unauthorized` nommant `write:scans` ; la même clé appelant `search_hosts` réussit.

- [ ] **5.3 Audit des appels d'outils**
  - **Notes** : Table d'audit append-only ; ligne écrite en moins de 1 s pour chaque appel d'outil.
  - **Test plan** : Test d'intégration invoque chaque outil une fois et assure qu'une ligne d'audit correspondante existe en moins de 1 s avec `key_id`, `tool_name`, `duration_ms`.

- [ ] **5.4 TLS exigé**
  - **Notes** : Le listener HTTP+SSE refuse les connexions sans TLS ; HSTS activé.
  - **Test plan** : Tentative HTTP en clair refusée avec raison `tls-required` ; tentative HTTPS valide réussit ; l'en-tête `Strict-Transport-Security` est présent.

---

## 6. Conformité RGPD — spec : `gdpr-compliance`

- [ ] **6.1 Liste blanche des régions au déploiement et au runtime**
  - **Notes** : Précondition Terraform + self-check runtime au boot lisant les métadonnées cloud. Liste blanche : `{eu-west-3, eu-central-1, fr-par, nl-ams, de-fra}`. Inclure une vérification que les paires source/destination de réplication sont toutes deux EU.
  - **Test plan** : Plan CI avec `region=us-east-1` échoue avec `region-not-allowed` ; `region=fr-par` passe. Test de boot dans un container avec fake metadata `us-east-1` sort en non-zero. Test Terraform avec une réplication EU→non-EU est rejeté à `terraform plan`.

- [ ] **6.2 Workflow d'effacement (DSAR) multi-région**
  - **Notes** : UI opérateur + API. Vérification du contrôle requise (challenge DNS ou PoP signé). À l'approbation : tombstone dans le vector store, suppression chaud/froid dans **chaque région EU active**, entrée hashée dans le ledger d'audit.
  - **Test plan** : e2e avec horloge simulée — soumettre l'effacement, approuver, avancer l'horloge de 30 jours, assurer que toutes les références sont supprimées de `hosts`, `services`, index vectoriel et objets tier froid dans chaque région EU configurée ; assurer la présence d'une tombstone hashée dans le journal d'audit.

- [ ] **6.3 Journal d'audit append-only répliqué cross-région**
  - **Notes** : Table Postgres avec UPDATE/DELETE révoqués pour le rôle applicatif ; job journalier de checksum réplique vers backup S3 Object Lock avec rétention 24 mois ; réplication cross-région avec retard p99 < 5 s ; métrique `audit_replication_lag_seconds` exposée.
  - **Test plan** : `UPDATE`/`DELETE` direct sur la table d'audit échoue avec erreur de permission et la tentative est elle-même journalisée. Le job de checksum tourne et vérifie le snapshot de la veille. Test multi-région injecte une entrée et assure qu'elle est observable dans toutes les régions actives en < 5 s p99.

---

## 7. Plateforme — spec : `platform`

- [ ] **7.1 Authentification OIDC avec application des rôles**
  - **Notes** : OIDC ; choix d'IdP différé. JWT vérifié par requête ; le claim de rôle drive l'autorisation. Rôles : `owner`, `admin`, `analyst`, `viewer`, `mcp_client`. La couche d'auth doit être codée contre l'interface OIDC standard pour qu'un IdP soit substituable plus tard sans changer le code applicatif.
  - **Test plan** : Test paramétré par rôle exerce chaque endpoint et assure permis/refusé selon la matrice de rôle. Test additionnel monte un IdP fake conforme OIDC pour vérifier que l'app ne dépend d'aucune extension propriétaire.

- [ ] **7.2 Isolation multi-tenant (RLS + préfixe + queue) multi-région**
  - **Notes** : RLS Postgres deny-by-default ; pgvector hérite de la RLS ; préfixe S3 par tenant avec bucket policy ; queue partitionnée par tenant. Les politiques RLS sont préservées par la réplication cross-région.
  - **Test plan** : Sonde cross-tenant (1000 appels) renvoie 404 pour IDs existants-d'autre-tenant et IDs inexistants ; variance de timing < 10 ms (pas d'oracle). Tentative path-traversal sur le store objet refusée par bucket policy. Matrice (région × tenant) testée pour la non-fuite.

- [ ] **7.3 Intégration facturation Stripe EU**
  - **Notes** : Stripe Tax pour la TVA EU ; compteurs : scans, appels MCP, dépassement de rétention. Webhooks idempotents (dedup par event id).
  - **Test plan** : e2e en mode test Stripe : créer un tenant, simuler un mois d'usage compteur, assurer que les lignes de facture matchent les enregistrements d'usage émis et que les totaux sont corrects TVA incluse.

---

## 8. Documentation

- [ ] **8.1 Site de doc public (Docusaurus)** — référence API + référence outils MCP (HTTP+SSE) + page publique du process DSAR.
- [ ] **8.2 Runbooks internes** — réponse aux incidents, traitement DSAR, intake de plaintes pour abus de scan, bascule de région, suivi du retard de réplication.

---

## Acceptation pour le change dans son ensemble

- [ ] Chaque exigence des spec deltas ci-dessus a au moins un test automatisé passant en CI.
- [ ] La CI rejette toute fusion qui introduit une région non-EU dans l'IaC ou qui retire une politique de journal d'audit.
- [ ] Une commande de self-check documentée (`uv run reconaut doctor`) imprime région, défauts de rétention, fingerprint du modèle d'embedding, retard de réplication d'audit observé et politiques d'isolation tenant.
