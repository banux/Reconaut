# Tâches : reposition-as-agent-knowledge-base

Checklist du repositionnement narratif (drop MSSP, base de connaissance pour agents) et de l'introduction du tool MCP `ingest_scan_result` pour l'intégration entrante. Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Repositionnement narratif

- [x] **1.1 Réécrire `openspec/project.md`**
  - **Notes** : Section *Positionnement* : retirer les mentions « MSSP », « SOC analyste » comme persona principal. Reformuler en : « base de connaissance d'actifs internet maintenue par l'opérateur, queryable par ses agents IA et intégrable avec sa stack sécurité existante ». Section *Différenciateurs* : frontload « base de connaissance MCP-first pour agents IA » et « intégration entrante (ingestion de scanners externes) + sortante (export, et webhooks à venir) ». Section *Non-objectifs* : retirer les mentions « MSSP qui veut servir N clients déploie N instances » et la formulation multi-tenant (devenue caduque en mono-user).
  - **Test plan** : `grep -niE "mssp|hébergeur" openspec/project.md` ne renvoie aucune occurrence active. `grep -i "base de connaissance\|knowledge base" openspec/project.md` renvoie ≥ 2 matches. Une revue humaine confirme que la nouvelle introduction reflète la vision « base de référence pour agents ».

- [x] **1.2 Mettre à jour `init-reconaut-platform/proposal.md`**
  - **Notes** : Retirer ou reformuler les bullets non-objectifs qui référencent MSSP. Ajouter en non-objectifs : « Reconaut n'est pas un produit autonome de scan-puis-rapport ; c'est un composant de la stack sécurité de l'opérateur, intégré via MCP avec des agents et d'autres outils ».
  - **Test plan** : `grep -i "mssp" openspec/changes/init-reconaut-platform/proposal.md` ne renvoie aucune occurrence active.

- [x] **1.3 Mettre à jour `single-user-only/proposal.md`**
  - **Notes** : Le change `single-user-only` mentionne « un MSSP qui veut servir N clients déploie N instances » comme justification. Reformuler en « un opérateur qui veut isoler plusieurs périmètres déploie plusieurs instances » — sans nommer MSSP.
  - **Test plan** : `grep -i "mssp" openspec/changes/single-user-only/proposal.md` ne renvoie rien.

- [x] **1.4 Documenter le positionnement « base de connaissance pour agents »**
  - **Notes** : Nouvelle page `docs/positioning/agent-knowledge-base.md` qui explique : (a) le persona principal est l'opérateur orchestrateur d'agents IA, (b) Reconaut maintient un graphe d'actifs scopé alimenté par scans internes ET ingestion externe, (c) la consommation par agents passe par MCP, (d) les intégrations externes (entrante via `ingest_scan_result`, sortante via futurs webhooks) sont citoyens de première classe.
  - **Test plan** : La page existe et est référencée depuis le README racine.

---

## 2. Tool MCP `ingest_scan_result` — spec : `mcp-server` + `integrations`

- [x] **2.1 Implémenter `ingest_scan_result` dans `Mcp::CoreTools`**
  - **Notes** : Nouveau tool dans `apps/api/app/lib/mcp/core_tools.rb`. Scope `write:scans`. Le `params_schema` accepte un payload typé conforme `ScanResultV1`. Le handler valide via `JobSchema::Registry.validate("ScanResultV1", payload)`, vérifie le scope (réutiliser `Reconaut::ScanEnqueuer#ensure_in_scope!` ou un service partagé), persiste les rows correspondantes (Host/Service/Certificate, etc. — pour l'instant un service `Reconaut::ScanResultIngestor` à créer qui factorise la logique entre workers internes et ingestion externe).
  - **Test plan** : Spec d'intégration : (a) payload valide + scope OK → ingestion réussit + rows créées, (b) payload hors scope → `out-of-scope`, (c) payload mal formé → `invalid_payload` + liste d'erreurs JSON Schema, (d) rejouer le même payload → idempotent (audit `outcome=duplicate`, pas de seconde écriture).

- [x] **2.2 Service `Reconaut::ScanResultIngestor`**
  - **Notes** : Service Ruby qui factorise la logique « parse `ScanResultV1` → upsert hosts/services/certs ». Appelé par les workers Go (transitoirement, le worker écrit directement en DB ; à terme via une route MCP interne) ET par le tool `ingest_scan_result`. La factorisation garantit que le chemin d'ingestion est identique quelle que soit la source.
  - **Test plan** : Spec unitaire : injecte un `ScanResultV1` synthétique, vérifie les upserts. Idempotence par `idempotency_key`. Test d'intégration cross-source : un même hôte vu par worker interne + ingestion externe se matérialise avec `source=["internal", "external"]`.

- [x] **2.3 Tagging `source` sur les rows ingérées**
  - **Notes** : Étendre les modèles Host / Service (et autres si pertinent) avec un champ `sources` (jsonb array, pour absorber plusieurs origines sans migration ultérieure). Le `Reconaut::ScanResultIngestor` ajoute la source au tableau via `array_append` Postgres avec dédoublonnage.
  - **Test plan** : Migration ajoute `sources jsonb DEFAULT '[]'` aux tables concernées. Spec : injecter un host depuis worker interne (source=internal), puis depuis nmap (source=nmap), assurer que le row final a `sources=["internal", "nmap"]` sans duplicat. Tester aussi via les outils de lecture (`search_hosts`, `get_host`) : la source apparaît dans la réponse.

- [x] **2.4 Mise à jour `MCP::ToolsController` / liste des tools exposés**
  - **Notes** : Le request spec `spec/requests/mcp/tools_spec.rb` qui asserte la liste des tools doit inclure `ingest_scan_result`.
  - **Test plan** : Spec passe avec la nouvelle liste. `GET /mcp/tools` exposé via réponse JSON contient bien `ingest_scan_result` avec son scope.

---

## 3. Documentation des intégrations

- [x] **3.1 Page `docs/integrations/external-scanners.md`**
  - **Notes** : Documenter le pattern d'intégration : « pour pousser un résultat de scan externe (nmap, nuclei, etc.), produire un payload `ScanResultV1` puis appeler `ingest_scan_result` via MCP HTTP+SSE avec une clé API scopée `write:scans` ». Exemple concret avec un curl ou un script Ruby/Python minimal.
  - **Test plan** : La page existe ; un test fixture exécute le snippet d'exemple de la doc contre un Rails de test et vérifie l'ingestion.

- [x] **3.2 Mention du repositionnement dans `README.md`**
  - **Notes** : La première phrase du README doit refléter le repositionnement. « Reconaut est une base de connaissance d'actifs internet pour agents IA, auto-hébergeable, scope-driven, intégrable à votre stack sécurité existante. ».
  - **Test plan** : `head -1 README.md` matche `/base de connaissance.*agent/i`.

---

## 4. Acceptance pour le change dans son ensemble

- [x] **4.1 Tests automatisés `ingest_scan_result`**
  - Au moins quatre specs : happy path, hors scope, payload invalide, idempotence par `idempotency_key`.

- [x] **4.2 Source tagging vérifiable via les outils de lecture**
  - Test : ingérer un host avec `source=nmap` ; faire un `search_hosts` ; vérifier que le résultat porte `source=["nmap"]`. Idem pour un host hybride internal + nmap.

- [x] **4.3 Linter narratif**
  - `scripts/check_no_mssp.sh` (peut être inclus dans `scripts/check_stack.sh`) qui rejette toute introduction du mot « MSSP » dans `openspec/`, `docs/`, `README.md`. Le linter passe propre après l'implémentation.

- [x] **4.4 La routine `system_doctor` reste cohérente**
  - Pas de régression sur le rapport `Reconaut::Doctor` ; ajouter optionnellement un check `ingestion_endpoint_reachable` (info-level, vérifie que `ingest_scan_result` est bien enregistré au boot).
