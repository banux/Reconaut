# Change : add-graph-retrieval

## Pourquoi
La spec `agent-interface` initialisée par `init-reconaut-platform` repose sur un RAG vectoriel pur : embedder pluggable (modèle local par défaut, Ollama / `mistral-embed` / OpenAI-compatible optionnels par variable d'environnement) + pgvector + top-k=5. Cette stack répond bien aux requêtes sémantiques sur du texte libre (bannières, extraits HTML, fingerprints) mais rate les requêtes **structurelles** qui font la valeur d'un Shodan-like européen open source auto-hébergeable :

- « Quels hôtes partagent ce certificat TLS feuille ? » (cluster de réutilisation de cert)
- « Modbus exposés sur les domaines du périmètre déclaré » (chaîne Domain → Host → Service)
- « Voisinage réseau d'un hôte compromis » (AS + range IP + cert cluster, multi-saut)
- « Hôtes hébergeant une CVE critique sur un service public » (jointure CPE → vulnérabilité)

Ces requêtes sont par nature des **parcours de graphe**. Un RAG vectoriel n'a pas de notion de chemin et retourne du texte plat — ce qui pousse le LLM à halluciner les relations.

La note de recherche `openspec/research/graph-rag.md` trace deux familles de Graph RAG et écarte celle « index-time LLM extraction » (Microsoft GraphRAG, LightRAG, Graphiti) : notre dataset est déjà structuré, faire passer chaque scan au LLM pour ré-extraire des entités déjà typées coûte des tokens, accroît l'exposition RGPD et — surtout — casse la promesse d'auto-hébergement sans condition (`project.md`) en transformant le graphe en sous-produit d'un LLM externe que l'opérateur n'a pas forcément configuré. La famille « native graph data » (Cypher sur graphe existant) est l'angle adapté.

Ce change formalise l'adoption d'une couche de retrieval graphe **complémentaire** au RAG vectoriel existant, et fait évoluer le pipeline de l'agent vers un retrieval hybride.

## Ce qui change

1. **Nouvelle capacité `graph-retrieval`** :
   - Projection graphe du modèle de scan (Domain, Host, Service, Certificate, AS, IPRange, CPE, Vulnerability — modèle tenant unique, pas de label Tenant) matérialisée dans **Apache AGE** sur le cluster Postgres existant.
   - Catalogue de **templates de requête paramétrés** (en lecture seule). Le LLM **ne génère pas de Cypher arbitraire** : il sélectionne un template et lui passe des paramètres. Cela ferme la surface d'injection Cypher et rend l'audit déterministe.
   - Pipeline de retrieval hybride : ancrage vectoriel pour le rappel sémantique, expansion graphe (1–3 sauts) pour le contexte structurel, synthèse LLM avec citations par nœud visité.
   - Rafraîchissement borné : le graphe reflète l'état des données de scan avec une staleness bornée (cible : p95 < 60 s après ingestion).
   - Audit : chaque exécution de template enregistre le `template_id`, les paramètres, le `key_id`/`user_id` du caller, la durée et le nombre de nœuds touchés.
   - Effacement par identifiant : la suppression d'un `host_id`, domaine ou IP retire les nœuds et arêtes correspondants dans la même transaction Postgres que la suppression des lignes scalaires (cohérent avec `gdpr-compliance`).

2. **Modification de `agent-interface`** :
   - L'exigence de retrieval devient explicitement **hybride** (vector + graph). Les scénarios existants (top-k vectoriel, citations, résilience embedder externe) restent valides ; on ajoute des scénarios pour les requêtes structurelles, le contrôle d'accès par RBAC, et la dégradation gracieuse quand le graphe est indisponible.

## Contraintes

- **Apache AGE sur le cluster Postgres existant**, pas de nouveau moteur graphe (Neo4j, Memgraph, FalkorDB, Kuzu, Neptune) en v1. Justifications cumulées : (a) la RLS Postgres exigée par `platform/spec.md` s'applique sans réécriture, (b) la réplication multi-actif EU passe par le WAL Postgres déjà spécifié, (c) la suppression DSAR reste une transaction unique, (d) pas de nouveau sous-traitant Art. 28 à contractualiser, (e) Apache AGE est sous **licence Apache 2.0** et donc compatible avec une distribution Reconaut sous AGPL-3.0-only. Les alternatives écartées posent au moins un de ces problèmes : Memgraph est sous BSL 1.1 (non-OSI), FalkorDB sous SSPL (non-OSI), Neo4j Enterprise sous licence propriétaire, Neptune AWS-only.
- **Pas de Cypher généré par LLM**. Le LLM ne fait que choisir un `template_id` et fournir des paramètres typés. Le code applicatif Rails exécute le Cypher du template avec les paramètres bindés (équivalent paramétré à un prepared statement). Toute requête hors catalogue DOIT être refusée.
- **Templates en lecture seule**. Le rôle Postgres utilisé pour exécuter les templates n'a pas le droit `CREATE`/`DROP`/`MATCH ... DETACH DELETE`/écriture sur les labels graphe. Les templates qui muteraient le graphe sont rejetés à l'enregistrement.
- **Pas d'extraction LLM à l'index ; pas de LLM requis pour faire tourner le graphe**. Le graphe est dérivé déterministiquement des données de scan structurées. Aucun appel à un embedder ou LLM externe n'est effectué dans le chemin d'ingestion → projection. Une instance configurée 100 % réseau privé (modèle d'embedder local, pas de LLM externe) DOIT pouvoir construire et interroger le graphe sans émettre une seule requête sortante.
- **Cohérent avec `add-tech-stack`** : l'exécution des templates vit dans le process Rails (pas de microservice graphe). Les workers Go ne touchent pas au graphe — ils écrivent des résultats de scan structurés (via GoodJob ou directement en DB) que l'ingestion Rails projette en nœuds/arêtes.
- **Cohérent avec le modèle tenant unique** (cf. spec `platform`) : pas de filtre `tenant_id` dans les templates Cypher. Le contrôle d'accès est porté par l'authentification + RBAC.

## Non-objectifs (hors scope de ce change)

- **Outils MCP de parcours de graphe** (`get_neighbors`, `find_certificate_cluster`, `find_path`) — différés au futur change `add-graph-mcp-tools`. Ce change couvre uniquement le pipeline interne de l'agent.
- **Génération automatique de Cypher par LLM**. Conscient et délibéré ; voir contraintes.
- **Détection automatique de communautés / résumés hiérarchiques** (Leiden, MS GraphRAG style). Non pertinent pour un dataset structuré.
- **Algorithmes de graphe avancés** (PageRank, betweenness, motif mining) — réévaluables plus tard une fois les templates de base utilisés en production.
- **Migration vers un moteur graphe natif** (Neo4j et al.) — réévaluable si AGE plafonne sur les requêtes utiles à un débit acceptable.
- **UI d'exploration de graphe** côté Vue — peut faire l'objet d'un change frontend séparé.

## Décisions prises

1. **Apache AGE plutôt que Neo4j / Memgraph / FalkorDB / Kuzu / Neptune** — Justifié par la cohérence d'isolation (RLS), la cohérence de réplication multi-actif EU (WAL Postgres unique), la cohérence DSAR (transaction unique), l'absence de nouveau sous-traitant à contractualiser, l'absence de nouvelle astreinte opérationnelle, et la compatibilité de licence (Apache 2.0 sur AGPL-3.0-only). Les options écartées ont chacune au moins un blocker côté licence (BSL/SSPL/propriétaire) ou côté stack (deuxième DB à opérer, embedded mono-process).
2. **Templates paramétrés plutôt que Cypher généré par LLM** — Justifié par la sécurité (zéro surface d'injection Cypher), l'auditabilité (chaque appel = un `template_id` + paramètres déterministes) et la prédictibilité de performance (chaque template peut être profilé et indexé).
3. **Retrieval hybride, pas remplacement** — Le RAG vectoriel reste utile pour le rappel sémantique sur texte libre (bannières HTTP, extraits HTML). Le graphe ajoute le contexte structurel. Les deux sont composés à la requête, pas mutuellement exclusifs.
4. **Synthèse LLM avec citations par nœud** — Chaque résultat porte la liste des nœuds graphe visités et leurs `(host_id, scanned_at)` correspondants ; la traçabilité de provenance est préservée comme dans `agent-interface` v1.
5. **Pas de bi-temporalité (validity windows par arête) dans la v1** — Le pattern Graphiti `valid_from`/`valid_until` par fait est conceptuellement intéressant pour répondre à « ce service était-il exposé le jour X ? ». Reconaut a déjà partiellement ça via TimescaleDB (`scanned_at` sur les lignes scalaires). Formaliser des fenêtres de validité par arête graphe ajoute du coût d'ingestion et un schéma plus lourd ; on s'en passe en v1 et on traitera la question de la « vue historique du graphe » dans un change séparé `add-graph-temporal-validity` si le besoin s'avère réel.

## Différé (non bloquant, parqué pour plus tard)

- **Outils MCP de parcours de graphe** — change séparé `add-graph-mcp-tools` une fois le pipeline interne stabilisé.
- **Cache des résultats de templates fréquents** — à introduire après mesure des hot paths en production.
- **Catalogue exhaustif de templates** — la v1 livre un set noyau (≤ 10 templates) couvrant les cas mesurés en interne ; l'extension du catalogue se fera par changes incrémentaux.
- **Métrique de qualité graph-RAG vs vector-only** — set d'évaluation golden à constituer empiriquement, formalisable dans un change `add-retrieval-quality-evals`.
- **Bi-temporalité par arête (`valid_from`/`valid_until`)** — différée à un éventuel `add-graph-temporal-validity` ; la v1 expose un graphe « état courant » dérivé du dernier scan connu.
