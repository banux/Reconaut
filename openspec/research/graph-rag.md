# Note de recherche : Graph RAG pour Reconaut

Statut : note de cadrage, pas un change OpenSpec. Sert à décider du périmètre d'un futur change `add-graph-retrieval` (ou équivalent).

## 1. Pourquoi cette note

L'agent conversationnel actuellement spécifié dans `agent-interface` repose sur un RAG vectoriel classique : embedder pluggable (par défaut un modèle local in-process, Ollama / `mistral-embed` / OpenAI-compatible activables par variable d'environnement) → index pgvector → top-k=5 → réponse LLM avec citations `(host_id, scanned_at)`. Ce design répond bien aux requêtes sémantiques sur du texte libre (bannières HTTP, extraits HTML, fingerprint de logiciel) mais **rate les requêtes structurelles** qui font la valeur d'un Shodan-like :

- « Quels hôtes partagent ce certificat TLS feuille ? » (cluster de réutilisation de cert)
- « Modbus exposés sur les domaines du périmètre déclaré » (parcours Domain → Host → Service)
- « Voisinage réseau d'un hôte compromis » (AS + range IP + cert cluster, multi-saut)
- « Hôtes hébergeant une CVE critique sur un service public » (jointure CPE → CVE)

Ces requêtes sont par nature **graphes** : nœuds (Host, Service, Certificate, AS, Vulnerability, Domain — modèle tenant unique, pas de nœud Tenant) et arêtes (héberge, présente, partage, est-vulnérable). Le RAG vectoriel n'a pas de notion de chemin et retourne du texte plat.

Graph RAG est une famille de techniques qui combine retrieval sur graphe (parcours, voisinage, sous-graphe) et génération LLM. La question de cette note : **est-ce pertinent pour Reconaut, et sous quelle forme ?**

## 2. Qu'est-ce que Graph RAG (état du domaine)

Deux familles, à ne pas confondre :

### 2.1 Graph-RAG « index-time construction » (corpus non structuré)
Frameworks qui partent de **texte non structuré**, demandent à un LLM d'extraire entités et relations, et construisent un graphe à l'index. Représentants :

- **Microsoft GraphRAG** (MIT, Python) — extraction LLM + détection de communautés (Leiden) + résumés hiérarchiques par communauté. Coûteux en tokens à l'index (chaque chunk passe au LLM). Cible : grands corpus textuels (rapports, transcripts, bases de connaissances).
- **LightRAG** (HKU, MIT) — variante plus légère, retrieval dual (entité bas-niveau + thème haut-niveau).
- **LlamaIndex Property Graph Index** (MIT) — pluggable (Neo4j / Memgraph / Kuzu), extraction LLM guidée par schéma.

**Pertinence pour Reconaut : faible.** Notre dataset est **déjà structuré** (Host, Service, Cert sont des lignes typées en base). Faire passer chaque scan au LLM pour ré-extraire des entités déjà présentes est un coût LLM pur sans valeur ajoutée. C'est aussi **incompatible avec la promesse d'auto-hébergement sans condition** (`project.md`) : forcer un appel LLM externe à l'index transformerait le graphe en sous-produit d'un sous-traitant payant, alors que l'opérateur peut tourner aujourd'hui en réseau privé avec un embedder local. Et sur le volet exposition de données, multiplier les passages au LLM augmente la quantité de données techniques envoyées à un éventuel sous-traitant (Mistral, OpenAI-compatible) sans bénéfice. À écarter.

### 2.2 Graph-RAG « native graph data » (graphe existant)
Le graphe est déjà là, dérivé du modèle de données métier. Le RAG = traduction LLM d'une requête naturelle en parcours de graphe (Cypher, SPARQL, Gremlin, ou un DSL maison), exécution, puis synthèse LLM avec citations sur les nœuds visités. Représentants :

- **Neo4j GraphRAG** (package Apache 2.0, depuis 2024) — pipeline hybride pgvector + Cypher, support natif des citations par nœud. Le moteur Neo4j Community est sous **GPLv3** (auto-hébergeable), Enterprise sous licence commerciale propriétaire.
- **LangChain GraphCypherQAChain** (MIT) — LLM génère du Cypher à partir du langage naturel ; exécute contre Neo4j/Memgraph.
- **Apache AGE** (Apache 2.0, extension Postgres) — donne Cypher *sur Postgres*. Mature mais moins riche que Neo4j côté algos de graphe.
- **Kuzu** (MIT, embedded) — très rapide, modèle embedded mono-process.

**Pertinence pour Reconaut : forte.** C'est l'angle à creuser.

### 2.3 Cas particulier : Graphiti (Zep, 2024)
**Graphiti** ([github.com/getzep/graphiti](https://github.com/getzep/graphiti), Apache 2.0, Python) mérite un traitement séparé : il a beaucoup de visibilité dans l'écosystème agent et est régulièrement cité comme « le » framework Graph RAG moderne.

**Ce que c'est** : un framework de construction de **graphe de connaissance temporel pour mémoire d'agent**. Idée centrale : les agents ingèrent des « épisodes » (texte brut, JSON structuré, message de chat), un LLM en extrait entités + relations, et le graphe enregistre des **validités bi-temporelles** (quand un fait est devenu vrai, quand il a été invalidé). Le graphe évolue en continu, fait par fait, sans recalcul global. Schéma personnalisable via Pydantic.

**Backends supportés** : Neo4j (par défaut/recommandé), FalkorDB, Kuzu, Amazon Neptune.

**LLM/embedders** : OpenAI (défaut), Anthropic, Gemini, Azure OpenAI, Groq, Ollama, Voyage. Self-hostable de bout en bout via Ollama + Neo4j Desktop / FalkorDB.

**Serveur MCP** : un MCP server officiel Graphiti existe.

**Famille** : Graphiti est conceptuellement un **2.1 amélioré** — il *requiert* un appel LLM à l'index pour extraire entités/relations depuis chaque épisode. Différence vs MS GraphRAG : extraction incrémentale (par épisode) plutôt que batch global, et bi-temporalité native plutôt que résumés de communauté.

**Pertinence pour Reconaut** :
- **Adoption directe : non.** Notre dataset est déjà structuré (Host, Service, Cert sont des lignes typées sortant des workers Go) ; faire passer chaque scan au LLM pour extraire ce qu'on a déjà serait absurde et contraire à la promesse « auto-hébergement sans condition » (forcerait un LLM même pour ingérer un scan).
- **Backends incompatibles avec notre stack** : aucun support Postgres/AGE. Neo4j → casse « Postgres unique » et amène la pression Enterprise. FalkorDB → **licence SSPL (non-OSI)** incompatible avec l'identité AGPL-3.0 du projet. Kuzu → embedded mono-process, inadapté à Rails monolithe + workers Go séparés. Neptune → AWS-only propriétaire.
- **Idées à reprendre conceptuellement** :
  - **Bi-temporalité** (`valid_from` / `valid_until` par fait/relation). Reconaut a déjà partiellement ça via TimescaleDB (`scanned_at`), mais formaliser que chaque arête « Host héberge Service » porte une fenêtre de validité issue des scans est une bonne idée — utile pour répondre à « ce service était-il exposé le jour X ? » sans rejouer le scan.
  - **Provenance explicite par épisode** : chaque arête trace son origine (ici : `scan_id`/`scan_run_id`). Aligné avec le modèle d'audit déjà spécifié.
  - **Schéma de nœuds/arêtes typé via classes** (Pydantic chez eux ; côté Rails on aurait des `ActiveRecord::Base` ou des dataclasses Sorbet/RBS) — utile pour valider la projection scan → graphe.
- **Verdict** : ne pas embarquer Graphiti comme dépendance ; lire son code pour le pattern bi-temporel et la structure de provenance, et décider au change `add-graph-retrieval` si on veut formaliser les fenêtres de validité dès la v1 ou les différer.

## 3. Mapping sur le dataset Reconaut

Le modèle implicite issu des spec deltas existants est déjà un graphe :

```
Domain ──(résout)──► Host ──(présente)──► Service ──(implémente)──► CPE ──(matche)──► Vulnerability
                       │
                       ├──(sert)──► Certificate ──(partagé avec)──► Host (autre)
                       │
                       ├──(IN_AS)──► AutonomousSystem
                       │
                       └──(IN_RANGE)──► IPRange
```

(Modèle tenant unique : pas de nœud `Tenant`. Le périmètre des actifs est porté par la liste de scope déclarée par l'opérateur, pas par une notion de tenant dans le graphe.)

Arêtes intéressantes pour les requêtes :
- `Certificate ↔ Host` (cardinalité 1:N, où le N est exactement le cluster d'usage du cert) — typiquement les requêtes de surface d'attaque.
- `AS ↔ Host` (1:N grand, filtrable par pays).
- `Domain ↔ Host` (chaîne de découverte depuis le scope déclaré).
- `Service ↔ CPE ↔ Vulnerability` (requêtes de risque).

## 4. Options techniques pour le stockage graphe

Reconaut est distribué sous **AGPL-3.0-only**. Toute dépendance graphe doit être (a) auto-hébergeable sans clé propriétaire ni quota imposé par un éditeur, (b) sous une licence open source compatible avec une distribution AGPL-3.0 d'un produit qui l'embarque ou le requiert, (c) sans télémétrie sortante imposée. La colonne « Licence » ci-dessous reflète cet axe d'analyse.

| Option | Licence | Pour | Contre | Self-hostable | Cohérent avec stack Reconaut |
|---|---|---|---|---|---|
| **Apache AGE (extension Postgres)** | Apache 2.0 | Reste dans Postgres existant ; pas de nouveau fournisseur ni service ; transactions globales avec les tables OLTP ; aucune télémétrie sortante | Maturité moindre que Neo4j ; performance dégradée sur traversées profondes (>5 sauts) ; communauté plus petite | ✅ même cluster Postgres | ✅ aligné sur la stack figée (Postgres unique TimescaleDB+pgvector+AGE) |
| **Neo4j Community auto-hébergé** | GPLv3 (Community) — Enterprise propriétaire | Outillage le plus riche, bibliothèque GraphRAG officielle, algos de graphe matures | Nouvelle DB à opérer ; périmètre d'auth/audit séparé du backend Rails ; effacement DSAR distribué à concevoir ; les algos avancés (GDS production) sont en Enterprise propriétaire — incohérent avec « auto-hébergement sans condition » s'ils deviennent nécessaires | ✅ Community Edition | ❌ casse la promesse « Postgres unique » |
| **Memgraph auto-hébergé** | **BSL 1.1** (conversion Apache 2.0 différée) + MAGE Apache 2.0 | Compatible Cypher, performant, ancrage Postgres natif via connecteurs | **Licence Business Source non-OSI** : restrictions d'usage commercial concurrent jusqu'à conversion, mal vue dans l'écosystème open source et incohérente avec l'esprit AGPL-3.0 du projet ; charge opérationnelle d'une seconde DB | ⚠️ techniquement oui mais sous BSL | ❌ deuxième DB + risque de message contradictoire « open source » |
| **Kuzu (embedded)** | MIT | Très rapide, pas de réseau, embedded ; licence très permissive | Embedded mono-process — couplé au binaire qui le charge ; pas adapté à un Rails monolithe + workers Go séparés | N/A | ❌ |
| **Pure SQL/JOINs sur Postgres (pas de Cypher)** | PostgreSQL (Postgres) | Zéro nouveau composant ; LLM génère du SQL ; tout en ActiveRecord | Requêtes de chemin profondes très verbeuses ; pas de WITH RECURSIVE pratique pour `find_path` arbitraire | ✅ | ✅ mais perd la valeur graphe |
| **Vue dérivée graphe-en-mémoire** (NetworkX/gonum, chargé à la volée) | BSD-3 (NetworkX) / BSD-3 (gonum) | Simple ; algos riches en lib ; aucune nouvelle dépendance persistante | Ne scale pas au-delà de quelques millions d'arêtes ; rechargement coûteux | ✅ | ⚠️ acceptable pour un prototype |

## 5. Architecture pressentie pour Reconaut

**Hybrid retrieval, AGE-first, vector-secondary** :

1. **Conserver pgvector + l'embedder pluggable** (modèle local par défaut, Ollama / `mistral-embed` / OpenAI-compatible activables par env, cf. `project.md`) pour le rappel sémantique sur les champs textuels libres (bannière, extrait HTML, fingerprint logiciel). Inchangé par rapport à `agent-interface`.
2. **Ajouter Apache AGE** sur le même cluster Postgres pour matérialiser le graphe d'actifs. Apache 2.0, donc compatible avec une distribution AGPL-3.0 du produit. Les nœuds AGE sont des lignes Postgres → la RLS de `platform/spec.md` s'applique sans modification → cohérent avec la décision multi-actif EU (réplication via WAL Postgres standard) → conforme à la contrainte de l'isolation à la couche la plus basse, et zéro nouveau service à auto-héberger pour l'opérateur.
3. **Pipeline de retrieval** dans l'agent :
   - Décomposition de la requête utilisateur (LLM choisi par l'opérateur, par défaut local) en deux composantes : une partie sémantique (mots-clés) + une partie structurelle (entités nommées, relations).
   - Récupération vectorielle sur la partie sémantique → ensemble candidat de `host_id`.
   - Parcours graphe ancré sur cet ensemble (Cypher sur AGE) → sous-graphe contextuel (1–3 sauts).
   - Le LLM produit la réponse avec citations sur les nœuds visités du sous-graphe.
4. **Outils MCP** pour exposer le graphe aux agents externes (futur change `add-graph-mcp-tools`) : `get_neighbors(node_id, depth)`, `find_certificate_cluster(cert_sha256)`, `find_path(from, to, max_depth)`.
5. **Pas d'extraction LLM à l'index**. Le graphe est dérivé déterministiquement des données de scan déjà structurées. Aucun token d'embedder externe consommé pour construire le graphe ; une instance configurée 100 % local reste 100 % local.

## 6. Implications cross-cutting

- **Effacement par cible** : la cohérence du workflow d'effacement (cf. `init-reconaut-platform §6.2`, retiré du framing RGPD par `drop-gdpr-framing`) exige que la suppression d'un `host_id` retire les nœuds *et* les arêtes du graphe. Avec AGE = même transaction Postgres que la suppression des lignes scalaires → cohérence triviale. Avec Neo4j séparé = workflow de suppression distribué à concevoir + tester.
- **Audit** : les requêtes Cypher générées par LLM doivent être journalisées (texte de la requête, durée, nombre de nœuds touchés). Risque d'injection Cypher = LLM peut générer des requêtes destructives (`DETACH DELETE`). Mitigation : runtime read-only pour les requêtes d'agent, allowlist de patterns Cypher, ou DSL restreint plutôt que Cypher brut.
- **Stack** : AGE = extension Postgres → s'installe via `CREATE EXTENSION age`, pas de service supplémentaire à déployer. Cohérent avec le change `add-tech-stack` (Rails 8 monolithe + workers Go + GoodJob). Côté Rails, gem `activerecord-age` ou requêtes brutes via `ActiveRecord::Base.connection.execute`.
- **Licence et écosystème open source** : Apache AGE (Apache 2.0) est compatible avec une distribution Reconaut sous AGPL-3.0-only et avec la promesse « auto-hébergement sans condition » (`project.md`). À l'inverse, Memgraph (BSL 1.1) introduirait une dépendance non-OSI dans la chaîne dont l'opérateur dépend pour faire tourner le produit, ce qui contredit l'esprit du projet ; et l'écosystème Neo4j pousse vers Enterprise (propriétaire) dès qu'on touche aux algos avancés (GDS production-grade). AGE évite les deux pièges.
- **Auto-hébergement sans condition** : avec AGE, l'opérateur peut tourner 100 % en réseau privé — graphe inclus. Aucun appel sortant n'est requis pour construire ou interroger le graphe ; les seuls appels LLM possibles restent ceux de l'embedder/agent que l'opérateur a explicitement configurés (modèle local par défaut). Ajouter un moteur graphe externe (cloud Neo4j AuraDB, cloud Memgraph, etc.) casserait cette propriété — donc explicitement hors scope.
- **Coût** : zéro coût marginal d'embedder pour la construction du graphe (vs MS GraphRAG qui coûte des centaines de dollars en tokens pour un corpus moyen, et qui surtout *exige* un fournisseur LLM externe). Coût LLM uniquement à la requête, et uniquement si l'opérateur a configuré un embedder/LLM payant — sinon zéro.

## 7. Recommandation

**Phase 1 (change `add-graph-retrieval`)** : adopter Apache AGE sur Postgres, projeter le modèle de scan en graphe (vue matérialisée graphe rafraîchie après ingestion), implémenter le pipeline hybride vector + Cypher dans l'agent. Pas d'API Cypher brute exposée. Le LLM ne génère pas de Cypher arbitraire — il sélectionne parmi un petit ensemble de templates de requête paramétrés (sécurité + auditabilité).

**Phase 2 (change `add-graph-mcp-tools`)** : exposer les outils MCP de parcours après que le pipeline interne soit stable.

**À NE PAS faire** :
- Construire un graphe via extraction LLM à l'index (MS GraphRAG style) — coût LLM, exposition de données techniques à un sous-traitant sans bénéfice, et incompatibilité avec une instance auto-hébergée 100 % réseau privé.
- Adopter Neo4j en v1 — recrée un périmètre d'auth, casse l'invariant « isolation à la couche la plus basse », alourdit la conformité multi-actif EU, et expose à la pression « passe en Enterprise propriétaire » dès qu'on veut des algos avancés.
- Adopter Memgraph en v1 — la licence BSL 1.1 (non-OSI) est en porte-à-faux avec l'identité open source AGPL-3.0 du projet et la promesse d'auto-hébergement sans condition.
- Adopter un service graphe managé propriétaire (Neo4j AuraDB, Memgraph Cloud, TigerGraph Cloud, etc.) — casse frontalement la promesse d'auto-hébergement et réintroduit un sous-traitant Art. 28.
- Laisser le LLM générer du Cypher arbitraire — risque d'injection et d'erreurs silencieuses.

## 8. Questions ouvertes (à trancher au change `add-graph-retrieval`)

1. **AGE vs SQL pur avec WITH RECURSIVE**. Si la majorité des requêtes utiles sont 1–2 sauts, est-ce qu'AGE vaut la complexité ou un schéma SQL bien indexé suffit ?
2. **Templates de requête vs Cypher généré**. Combien de templates couvrent 80 % des intentions utilisateur ? (à mesurer empiriquement sur des logs d'agent une fois la v1 livrée).
3. **Rafraîchissement du graphe** : trigger à l'ingestion de chaque scan, ou job batch toutes les N minutes ? Trade-off fraîcheur vs charge.
4. **Métriques de qualité graph RAG** : comment mesurer qu'on bat le RAG vectoriel pur ? Set d'évaluation à constituer (10–20 requêtes structurelles golden).
5. **Taille typique du graphe par instance** : nombre de nœuds/arêtes pour un opérateur moyen (échelle PME → grand groupe) ? Conditionne le choix entre AGE persistant et un graphe en mémoire chargé à la session.

## 9. Sources et frameworks à étudier plus en profondeur (avant le change)

- Microsoft GraphRAG (MIT) — pour comprendre l'approche communauté/résumé (mais à ne pas adopter telle quelle).
- Neo4j GraphRAG package (Apache 2.0) — patterns hybrides vector + graph que l'on peut reproduire sur AGE, indépendamment du moteur Neo4j.
- Apache AGE (Apache 2.0) — vérifier la compatibilité avec TimescaleDB sur le même cluster, performance de Cypher sur des graphes 10–100 M arêtes, support de la réplication logique multi-actif.
- LangChain GraphCypherQAChain (MIT) — patron de génération guidée vs templates.
- Article original « From Local to Global: A GraphRAG Approach » (Microsoft, 2024) — pour la terminologie partagée.
- Graphiti (Zep, Apache 2.0) — pour le pattern bi-temporel (validité d'un fait dans le temps) et la structure de provenance par épisode. À lire pour les idées, pas à embarquer (cf. § 2.3).
- Revue licence des dépendances ajoutées par le change — toute nouvelle gem Ruby / module Go embarqué avec le produit doit être OSI-approved et compatible AGPL-3.0 (proscrire BSL, SSPL, Elastic License v2, Commons Clause).

---

**Prochaine étape suggérée** : si la direction « AGE + retrieval hybride » est validée, je peux préparer un change OpenSpec `add-graph-retrieval` via `/ralphy-plan` qui formalisera (a) la projection graphe du modèle de scan, (b) le pipeline retrieval, (c) les templates de requête, (d) les métriques de qualité.
