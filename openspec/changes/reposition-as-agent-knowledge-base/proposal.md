# Change : reposition-as-agent-knowledge-base

## Pourquoi

Le positionnement actuel de Reconaut le présente comme un « outil OSS auto-hébergeable d'Attack Surface Management » dont le public cible est l'équipe sécurité interne, l'opérateur SOC, le MSSP, ou l'indépendant. Cette formulation reste valable mais sous-vend la valeur réelle du produit telle qu'elle se cristallise au fil des décisions :

1. **`mcp-as-primary-entrypoint`** acte que le MCP HTTP+SSE est le canal canonique. Tout consommateur — TUI humaine, agent IA externe, script CI — passe par MCP. La surface MCP est la surface produit.
2. **`add-graph-retrieval`** + l'embedder pluggable + l'index vectoriel font que Reconaut **stocke** un graphe d'actifs queryable sémantiquement et structurellement. Ce n'est pas un scanner-puis-rapport ; c'est une base de connaissance vivante.
3. **`single-user-only`** confirme que Reconaut n'a pas vocation à être un service multi-utilisateurs partagé : c'est un outil d'opérateur, intégré dans la stack de l'opérateur.

Conclusion logique : Reconaut n'est plus à positionner comme un « Shodan-like pour SOC » ou un « outil pour MSSP ». Reconaut est **une base de référence pour les agents IA et les autres outils de la stack sécurité** : il maintient un graphe d'actifs scopé par l'opérateur, il accepte que d'autres scanners y déposent leurs résultats, et il expose ce graphe via MCP pour que des agents (Reconaut's own agent + agents externes type Claude / GPT / agents maison) le consomment comme source faisant autorité dans leur raisonnement.

L'utilisateur acte ce repositionnement explicitement : retirer l'objectif MSSP, repositionner comme base de référence pour l'agent intégré avec d'autres outils.

## Ce qui change

1. **Repositionnement narratif** dans `openspec/project.md` et `init-reconaut-platform/proposal.md` :
   - Section Positionnement réécrite : « base de connaissance d'actifs internet pour agents IA, intégrée à la stack sécurité existante de l'opérateur ». Plus de mention de MSSP, plus de « SOC analyste » comme persona principal — le persona devient « l'opérateur qui orchestre des agents IA et veut leur donner une source d'autorité sur sa surface d'attaque ».
   - La section Différenciateurs frontload « base de connaissance queryable par agents » et « intégrations entrante/sortante » plutôt que « optimisation de scan IA ».
   - Section Non-objectifs : retirer les références « SaaS multi-tenant pour MSSP » et « MSSP qui veut servir N clients déploie N instances » (en mono-user, ces formulations n'ont plus de sens). Ajouter explicitement « pas un produit autonome de scan-puis-rapport ; Reconaut est un composant de la stack de l'opérateur ».

2. **Nouvelle capacité `integrations`** (légère, focalisée v1) :
   - Définit le principe : Reconaut accepte des **données entrantes** d'outils externes (résultats de scanners tiers : nmap, OpenVAS, Nuclei, Censys exports, etc.) et expose des **flux sortants** (au-delà de `export_report`, des hooks pour SIEM / threat intel / agents maison).
   - V1 livre uniquement une surface MCP `ingest_scan_result` qui accepte un payload conforme à `ScanResultV1` (le schéma déjà figé pour les workers Go) et le traite identiquement, qu'il vienne d'un worker interne ou d'une source externe.
   - Les autres formats d'entrée (nmap XML, OpenVAS, etc.) et les flux sortants webhook/SIEM sont différés à des changes ultérieurs (`add-nmap-import`, `add-webhook-notifications`, etc.).

3. **`agent-interface` recadré comme « interface de la base de connaissance »** :
   - Pas de modification de contrat fonctionnel. Modification de la *description* de la capacité : l'agent conversationnel, l'index vectoriel, le graphe AGE, et l'API MCP forment ensemble la « surface d'interrogation de la base de référence ». L'agent conversationnel interne et les agents IA externes consomment la même surface.

4. **`mcp-server` enrichi** :
   - Ajoute l'outil `ingest_scan_result` (scope `write:scans`).
   - Pas de nouveau transport, pas de nouvelle auth — réutilise tout ce qui existe.

## Contraintes

- **Pas de réintroduction d'une surface multi-utilisateurs**. Le pivot ne change pas le mode mono-user (cf. `single-user-only`). « Base de référence pour les agents » signifie agents au sens IA / outils, pas comptes humains additionnels.
- **Pas de fork du modèle scope-driven**. Les données ingérées via `ingest_scan_result` DOIVENT cibler des hôtes/CIDR/domaines couverts par le scope déclaré, exactement comme les scans internes. Pas de raccourci pour pousser des données hors scope « parce que ça vient de l'extérieur ».
- **Le MCP reste canal unique**. L'ingestion externe se fait via MCP (`ingest_scan_result`), pas via une nouvelle route REST `/ingest`.
- **Le contrat de message reste `ScanResultV1`**. On ne réinvente pas un format pour les imports — un client externe (par ex. un wrapper nmap → JSON) doit produire un `ScanResultV1` ou utiliser un futur convertisseur. Cela force une discipline de schéma.
- **Audit obligatoire sur l'ingestion**. Chaque appel `ingest_scan_result` produit une ligne d'audit avec `actor_key_id`, `target` et `source` (champ optionnel du payload, par ex. `"source": "nmap"`).
- **Pas de garantie sur la fraîcheur des données ingérées**. Si un client externe pousse des données vieilles, c'est sa responsabilité. Reconaut horodate l'ingestion et expose le timestamp original quand fourni.

## Non-objectifs (hors scope de ce change)

- **Connecteurs entrants concrets** (nmap, OpenVAS, Nuclei, Censys, Shodan import, certificate transparency feeds…) — chaque connecteur fait l'objet d'un change dédié. Ce change ne livre que le tool `ingest_scan_result` brut.
- **Connecteurs sortants concrets** (webhooks vers SIEM, push Splunk/Elastic, MISP, OpenCTI…) — différé à des changes ultérieurs.
- **Marketplace de connecteurs** ou système de plugins runtime — hors scope définitif. Si un connecteur n'est pas livré dans le repo, il est externe (un script tiers qui parle MCP).
- **Re-design de la surface MCP**. Le change ajoute un seul tool ; la matrice de scopes existante l'absorbe naturellement (`write:scans`).
- **Changement du schéma `ScanResultV1`**. Le schéma actuel sert pour les workers internes ET pour les imports externes — pas de variant.
- **Documentation détaillée des intégrations supportées**. Une page d'exemple suffit en v1 (`docs/integrations/external-scanners.md` esquissée), les guides détaillés viendront avec chaque connecteur.

## Décisions prises

1. **Reconaut = base de référence pour agents IA, pas produit autonome.** Le persona principal devient l'opérateur qui orchestre des agents IA contre sa surface d'attaque, pas l'analyste SOC qui clique dans une UI. Cette formulation justifie a posteriori toutes les décisions précédentes (MCP-first, mono-user, embedder pluggable, graphe AGE).
2. **Drop MSSP du champ produit.** L'OSS auto-hébergeable mono-user couvre les besoins d'un opérateur unique. Le pattern « MSSP qui sert N clients » sort du scope ; un MSSP qui veut faire ça doit construire son propre orchestrateur au-dessus de N instances Reconaut, ce n'est pas le boulot du projet.
3. **Surface d'intégration entrante = MCP tool `ingest_scan_result`.** Pas de nouvelle route REST, pas de nouveau transport, pas de nouveau format. On réutilise `ScanResultV1` qui est déjà le contrat des workers internes. Cohérence et discipline de schéma.
4. **Surface sortante = MCP tools existants** (`search_hosts`, `get_host`, `list_scans`, `export_report`) + un futur change pour webhook / push. Pas de nouvelle surface créée dans ce change.
5. **Capability `integrations` créée mais minimale.** Sert d'ancrage pour les futurs changes de connecteurs sans surcharger ce change.

## Différé (non bloquant, parqué pour plus tard)

- **Connecteur nmap** — change `add-nmap-import` qui livre un convertisseur nmap XML → `ScanResultV1` + un wrapper CLI (ou utilitaire Go côté worker).
- **Connecteur Nuclei / OpenVAS** — changes dédiés.
- **Webhook sortant sur changement d'état** — change `add-state-change-webhooks` qui pousse un payload signé vers une URL configurée par l'opérateur quand un host change d'état (ouverture de port, expiration de cert, etc.).
- **Push vers MISP / OpenCTI** — change spécifique threat intel.
- **Retraitement des données ingérées** (par ex. dédoublonnage cross-source) — réservé à un change `add-ingest-deduplication`.
