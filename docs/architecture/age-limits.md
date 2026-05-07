# Limites connues d'Apache AGE et politique de fallback

Reconaut adopte Apache AGE comme couche graphe (cf.
`openspec/research/graph-rag.md` et `openspec/changes/add-graph-retrieval/`).
Cette page documente les limites pratiques d'AGE et la politique de
fallback vers le retrieval vectoriel pur quand le graphe ne peut pas
repondre.

## Patterns a eviter

1. **Traversees non bornees**. `MATCH (a)-[*]->(b)` sur un graphe
   d'actifs scannes peut exploser combinatoirement (clusters de cert,
   AS denses). Toujours borner via `*1..3` au maximum, et utiliser
   `LIMIT`.
2. **Agregats globaux sans filtre**. `MATCH (n) RETURN count(n)` sur
   100 M arêtes va saturer un worker. Ancrer par label et par
   identifiant.
3. **`shortestPath` sur depth > 3**. AGE supporte `shortestPath` mais
   sa complexite croit vite. On borne explicitement a 3 dans
   `path_between` du set noyau.
4. **Cypher mutant glisse par mégarde dans un template**. Le linter
   `GraphTemplates::Registry.assert_read_only!` refuse a
   l'enregistrement ; en complement, le role Postgres utilise pour
   executer les templates n'a pas le droit `INSERT`/`UPDATE`/`DELETE`
   sur les tables AGE.
5. **OPTIONAL MATCH gourmand**. Un `OPTIONAL MATCH` qui ne se ferme
   pas peut multiplier les lignes. Bornes via `LIMIT` cote agregat.

## Politique de fallback

Si AGE est indisponible ou si une requete graphe depasse son timeout,
le pipeline de l'agent dégrade gracieusement vers le retrieval
vectoriel pur :

- Detection : exception `ActiveRecord::StatementInvalid` (extension non
  chargee), `Timeout::Error` (statement_timeout depasse), ou
  `permission denied` (mauvaise configuration role).
- Comportement : la reponse contient les resultats vectoriels au mieux,
  plus un avertissement structure `{ "warnings": ["graph_unavailable"] }`.
  Le pipeline ne fabrique JAMAIS de relations graphe en l'absence du
  graphe (cf. exigence `Graceful Degradation When Graph Unavailable`).
- Metriques : compteurs `graph_unavailable_total`,
  `graph_template_timeout_total{template_id}` exposes via Prometheus.

## Performances cibles

- `graph_lag_seconds` : p95 < 60 s, p99 < 300 s entre l'ingestion d'un
  scan et la disponibilite des arêtes correspondantes pour les
  templates (cf. `Bounded Graph Staleness`).
- Latence par template : p95 < 800 ms sur le set noyau, mesuree en CI
  une fois le test d'integration AGE actif.
- Timeout par template : 1500 ms (configurable via env). Au-dela,
  abandon + fallback.

## Cohabitation TimescaleDB + pgvector + AGE

Les trois extensions vivent sur la meme instance Postgres. Conflits
connus :

- AGE force `search_path = ag_catalog, "$user", public` pour ses
  fonctions `cypher()`. On le pose au niveau session via un
  initializer Rails, pas globalement, pour ne pas masquer les schemas
  de pgvector / TimescaleDB.
- TimescaleDB hyper-tables : pas d'interaction directe avec AGE. Les
  noeuds graphe sont des lignes sur des tables `ag_label_*` separees ;
  les hyper-tables vivent dans le schema metier.
- pgvector : la colonne `vector` est portee par les tables OLTP, pas
  par les nodes AGE. La recherche vectorielle reste disjointe de la
  traversee graphe ; l'agent compose les deux a la requête.

## Scenarios de panne et runbook minimal

- **AGE non chargee** : `LOAD 'age'` echoue au boot d'une session.
  Cause probable : extension non installee dans l'image Postgres.
  Remediation : reconstruire `ops/postgres/Dockerfile`. La routine
  `doctor` echoue avec `graph-extension-missing`.
- **Graphe `reconaut` absent** : `cypher('reconaut', ...)` echoue avec
  `graph reconaut does not exist`. Cause : migration `EnableGraph
  Extensions` jamais executee. Remediation : `bin/rails db:migrate`.
- **Timeout systematique** : `statement_timeout` trop bas, ou un
  template a des bornes trop laches. Remediation : augmenter le
  timeout pour ce `template_id` precis OU revoir la depth maximale.

## Sources

- Apache AGE manual : https://age.apache.org/age-manual/
- Reconaut graph-rag note : `openspec/research/graph-rag.md`
- Spec : `openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md`
