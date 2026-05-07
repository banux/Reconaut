# Note de recherche : Graph RAG pour Reconaut

Statut : note de cadrage, pas un change OpenSpec. Sert à décider du périmètre d'un futur change `add-graph-retrieval` (ou équivalent).

## 1. Pourquoi cette note

L'agent conversationnel actuellement spécifié dans `agent-interface` repose sur un RAG vectoriel classique : embed `mistral-embed` (1024-dim) → index pgvector → top-k=5 → réponse LLM avec citations `(host_id, scanned_at)`. Ce design répond bien aux requêtes sémantiques sur du texte libre (bannières HTTP, extraits HTML, fingerprint de logiciel) mais **rate les requêtes structurelles** qui font la valeur d'un Shodan-like :

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

- **Microsoft GraphRAG** (Apache 2.0, Python) — extraction LLM + détection de communautés (Leiden) + résumés hiérarchiques par communauté. Coûteux en tokens à l'index (chaque chunk passe au LLM). Cible : grands corpus textuels (rapports, transcripts, bases de connaissances).
- **LightRAG** (HKU, MIT) — variante plus légère, retrieval dual (entité bas-niveau + thème haut-niveau).
- **LlamaIndex Property Graph Index** — pluggable (Neo4j / Memgraph / Kuzu), extraction LLM guidée par schéma.

**Pertinence pour Reconaut : faible.** Notre dataset est **déjà structuré** (Host, Service, Cert sont des lignes typées en base). Faire passer chaque scan au LLM pour ré-extraire des entités déjà présentes est un coût Mistral pur, sans valeur ajoutée — et augmente l'exposition GDPR (plus de données envoyées à un sous-traitant). À écarter.

### 2.2 Graph-RAG « native graph data » (graphe existant)
Le graphe est déjà là, dérivé du modèle de données métier. Le RAG = traduction LLM d'une requête naturelle en parcours de graphe (Cypher, SPARQL, Gremlin, ou un DSL maison), exécution, puis synthèse LLM avec citations sur les nœuds visités. Représentants :

- **Neo4j GraphRAG** (officiel, depuis 2024) — pipeline hybride pgvector + Cypher, support natif des citations par nœud.
- **LangChain GraphCypherQAChain** — LLM génère du Cypher à partir du langage naturel ; exécute contre Neo4j/Memgraph.
- **Apache AGE** (extension Postgres) — donne Cypher *sur Postgres*. Mature mais moins riche que Neo4j côté algos de graphe.
- **Kuzu** (embedded) — très rapide, modèle embedded mono-process.

**Pertinence pour Reconaut : forte.** C'est l'angle à creuser.

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

| Option | Pour | Contre | Self-hostable | Cohérent avec stack Reconaut |
|---|---|---|---|---|
| **Apache AGE (extension Postgres)** | Reste dans Postgres existant ; pas de nouveau fournisseur ni service ; transactions globales avec les tables OLTP | Maturité moindre que Neo4j ; performance dégradée sur traversées profondes (>5 sauts) ; communauté plus petite | ✅ même cluster Postgres | ✅ aligné sur la stack figée (Postgres unique TimescaleDB+pgvector+AGE) |
| **Neo4j Community auto-hébergé** | Outillage le plus riche, bibliothèque GraphRAG officielle, algos de graphe matures | Nouvelle DB à opérer ; périmètre d'auth/audit séparé du backend Rails ; effacement DSAR distribué à concevoir | ✅ Community Edition | ❌ casse la promesse « Postgres unique » |
| **Memgraph auto-hébergé** | Compatible Cypher, performant, source-available | Charge opérationnelle d'auto-héberger une seconde DB ; conformité licence à vérifier | ✅ si auto-hébergé | ❌ deuxième DB à exploiter |
| **Kuzu (embedded)** | Très rapide, pas de réseau, embedded | Embedded mono-process — couplé au binaire qui le charge ; pas adapté à un Rails monolithe + workers Go séparés | N/A | ❌ |
| **Pure SQL/JOINs sur Postgres (pas de Cypher)** | Zéro nouveau composant ; LLM génère du SQL ; tout en ActiveRecord | Requêtes de chemin profondes très verbeuses ; pas de WITH RECURSIVE pratique pour `find_path` arbitraire | ✅ | ✅ mais perd la valeur graphe |
| **Vue dérivée graphe-en-mémoire** (NetworkX/networkx-go chargé à la volée) | Simple ; algos riches en lib | Ne scale pas au-delà de quelques millions d'arêtes ; rechargement coûteux | ✅ | ⚠️ acceptable pour un prototype |

## 5. Architecture pressentie pour Reconaut

**Hybrid retrieval, AGE-first, vector-secondary** :

1. **Conserver pgvector + `mistral-embed`** pour le rappel sémantique sur les champs textuels libres (bannière, extrait HTML, fingerprint logiciel). Inchangé par rapport à `agent-interface`.
2. **Ajouter Apache AGE** sur le même cluster Postgres pour matérialiser le graphe d'actifs. Les nœuds AGE sont des lignes Postgres → la RLS de `platform/spec.md` s'applique sans modification → cohérent avec la décision multi-actif EU (réplication via WAL Postgres standard) → conforme à la contrainte de l'isolation à la couche la plus basse.
3. **Pipeline de retrieval** dans l'agent :
   - Décomposition de la requête utilisateur (LLM Mistral) en deux composantes : une partie sémantique (mots-clés) + une partie structurelle (entités nommées, relations).
   - Récupération vectorielle sur la partie sémantique → ensemble candidat de `host_id`.
   - Parcours graphe ancré sur cet ensemble (Cypher sur AGE) → sous-graphe contextuel (1–3 sauts).
   - Le LLM produit la réponse avec citations sur les nœuds visités du sous-graphe.
4. **Outils MCP** pour exposer le graphe aux agents externes (futur change `add-graph-mcp-tools`) : `get_neighbors(node_id, depth)`, `find_certificate_cluster(cert_sha256)`, `find_path(from, to, max_depth)`.
5. **Pas d'extraction LLM à l'index**. Le graphe est dérivé déterministiquement des données de scan déjà structurées. Aucun token Mistral consommé pour construire le graphe.

## 6. Implications cross-cutting

- **GDPR / effacement par identifiant** : la cohérence du workflow d'effacement par identifiant (cf. `gdpr-compliance`) exige que la suppression d'un `host_id` retire les nœuds *et* les arêtes du graphe. Avec AGE = même transaction Postgres que la suppression des lignes scalaires → cohérence triviale. Avec Neo4j séparé = workflow de suppression distribué à concevoir + tester.
- **Audit** : les requêtes Cypher générées par LLM doivent être journalisées (texte de la requête, durée, nombre de nœuds touchés). Risque d'injection Cypher = LLM peut générer des requêtes destructives (`DETACH DELETE`). Mitigation : runtime read-only pour les requêtes d'agent, allowlist de patterns Cypher, ou DSL restreint plutôt que Cypher brut.
- **Stack** : AGE = extension Postgres → s'installe via `CREATE EXTENSION age`, pas de service supplémentaire à déployer. Cohérent avec le change `add-tech-stack` (Rails 8 monolithe + workers Go + GoodJob). Côté Rails, gem `activerecord-age` ou requêtes brutes via `ActiveRecord::Base.connection.execute`.
- **Coût** : zéro coût marginal Mistral pour la construction du graphe (vs MS GraphRAG qui coûte des centaines de dollars en tokens pour un corpus moyen). Coût LLM uniquement à la requête, comme aujourd'hui.

## 7. Recommandation

**Phase 1 (change `add-graph-retrieval`)** : adopter Apache AGE sur Postgres, projeter le modèle de scan en graphe (vue matérialisée graphe rafraîchie après ingestion), implémenter le pipeline hybride vector + Cypher dans l'agent. Pas d'API Cypher brute exposée. Le LLM ne génère pas de Cypher arbitraire — il sélectionne parmi un petit ensemble de templates de requête paramétrés (sécurité + auditabilité).

**Phase 2 (change `add-graph-mcp-tools`)** : exposer les outils MCP de parcours après que le pipeline interne soit stable.

**À NE PAS faire** :
- Construire un graphe via extraction LLM à l'index (MS GraphRAG style) — coût et exposition GDPR sans bénéfice.
- Adopter Neo4j en v1 — recrée un périmètre d'auth, casse l'invariant « isolation à la couche la plus basse », alourdit la conformité multi-actif EU.
- Laisser le LLM générer du Cypher arbitraire — risque d'injection et d'erreurs silencieuses.

## 8. Questions ouvertes (à trancher au change `add-graph-retrieval`)

1. **AGE vs SQL pur avec WITH RECURSIVE**. Si la majorité des requêtes utiles sont 1–2 sauts, est-ce qu'AGE vaut la complexité ou un schéma SQL bien indexé suffit ?
2. **Templates de requête vs Cypher généré**. Combien de templates couvrent 80 % des intentions utilisateur ? (à mesurer empiriquement sur des logs d'agent une fois la v1 livrée).
3. **Rafraîchissement du graphe** : trigger à l'ingestion de chaque scan, ou job batch toutes les N minutes ? Trade-off fraîcheur vs charge.
4. **Métriques de qualité graph RAG** : comment mesurer qu'on bat le RAG vectoriel pur ? Set d'évaluation à constituer (10–20 requêtes structurelles golden).
5. **Taille typique du graphe par instance** : nombre de nœuds/arêtes pour un opérateur moyen (échelle PME → grand groupe) ? Conditionne le choix entre AGE persistant et un graphe en mémoire chargé à la session.

## 9. Sources et frameworks à étudier plus en profondeur (avant le change)

- Microsoft GraphRAG — pour comprendre l'approche communauté/résumé (mais à ne pas adopter telle quelle).
- Neo4j GraphRAG package — patterns hybrides vector + graph que l'on peut reproduire sur AGE.
- Apache AGE — vérifier la compatibilité avec TimescaleDB sur le même cluster, performance de Cypher sur des graphes 10–100 M arêtes, support de la réplication logique multi-actif.
- LangChain GraphCypherQAChain — patron de génération guidée vs templates.
- Article original « From Local to Global: A GraphRAG Approach » (Microsoft, 2024) — pour la terminologie partagée.

---

**Prochaine étape suggérée** : si la direction « AGE + retrieval hybride » est validée, je peux préparer un change OpenSpec `add-graph-retrieval` via `/ralphy-plan` qui formalisera (a) la projection graphe du modèle de scan, (b) le pipeline retrieval, (c) les templates de requête, (d) les métriques de qualité.
