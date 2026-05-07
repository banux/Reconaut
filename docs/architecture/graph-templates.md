# Comment ajouter un template graphe

Cette page documente la procedure d'ajout d'un template Cypher dans le
catalogue de l'agent Reconaut.

Source de verite specs :
- `openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md`
  -> Requirement: Parameterized Read-Only Query Templates
- `openspec/changes/add-graph-retrieval/tasks.md` sections 3.1 / 3.2 / 3.3 / 3.4

## Principes intangibles

1. **Lecture seule.** Aucun template ne peut contenir `CREATE`, `MERGE`,
   `SET`, `DELETE`, `DETACH`, `REMOVE`. Le linter `assert_read_only!`
   refuse l'enregistrement et le role Postgres `reconaut_graph_reader`
   bloque toute mutation au cas ou le linter raterait quelque chose.
2. **Cypher fixe, parametres bindes.** Le Cypher est une chaine
   constante. Les valeurs viennent uniquement par parametres typed
   (`$nom`). Pas de concatenation, pas d'interpolation Ruby.
3. **Bornes strictes.** `depth in [1,3]`, `limit in [1,100]`, sauf
   surcharge explicite via `min`/`max` dans le schema.
4. **Pas de `tenant_id`.** Reconaut est tenant unique. Ni les Cypher,
   ni les parametres ne doivent porter cette dimension.
5. **Citations preservees.** Les templates retournent typiquement
   `host_id` + `scanned_at` pour que l'agent garde la tracabilite.

## Etapes

1. Choisir un `template_id` stable (snake_case, court, descriptif).
   Exemples : `cert_cluster`, `host_neighborhood`, `cve_exposed_count`.
2. Ouvrir `apps/api/app/lib/graph_templates/core_set.rb` (ou le module
   concerne pour les changes futurs) et ajouter une entree :

   ```ruby
   registry.register(
     id: "mon_template",
     params: {
       host_id: { type: :string, min_length: 1, max_length: 64 },
       depth:   { type: :integer }
     },
     cypher: <<~CYPHER
       MATCH (h:Host {id: $host_id})-[:EXPOSES]->(s:Service)
       WHERE s.proto = 'https'
       RETURN h.id AS host_id, s.port AS port, h.scanned_at AS scanned_at
       LIMIT 100
     CYPHER
   )
   ```

3. Ajouter une fixture spec sous `apps/api/spec/lib/graph_templates/`
   qui (a) charge le template, (b) appelle `Registry.resolve` avec un
   payload valide, (c) verifie que des parametres invalides sont
   rejetes (out-of-range, type errone, manquant).
4. Si le template introduit un nouveau label / nouvelle arete graphe,
   ajouter un index AGE et le documenter sous `docs/architecture/`.
5. `bundle exec rspec spec/lib/graph_templates/` doit etre vert.
6. `bin/test` doit passer toutes les suites.
7. Le test d'integration end-to-end (gate `DATABASE_INTEGRATION_TESTS=1`)
   seede un graphe minimal et verifie que le Cypher renvoie les nodes
   attendus. Couvre la partie execution reelle (non statique).

## Anti-patterns

- **Cypher concatene** : `"MATCH (h:Host {id: '#{id}'})"`. Toujours
  passer par `$id`.
- **`depth` non borne** : meme si Cypher accepte `*1..*`, on borne dans
  le validateur de parametres pour que l'agent ne demande jamais plus
  de 3 sauts.
- **Agregat sur tout le graphe** : `MATCH (n) RETURN count(n)`. Filtrer
  par label et / ou ancrer sur un id precis.
- **Cypher mutant glisse par accident** : par ex. `MERGE` pour creer
  un noeud manquant. Le linter le refuse a l'enregistrement, mais ce
  bloc finirait dans le graphe via `reconaut_graph_writer`, jamais via
  un template.

## Ressources

- Documentation Apache AGE : https://age.apache.org/age-manual/
- Note de recherche Reconaut : `openspec/research/graph-rag.md`
