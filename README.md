# Reconaut

Outil open source auto-hebergeable d'Attack Surface Management. Voir
`openspec/project.md` pour le positionnement complet et la stack figee.

## Layout monorepo

```
apps/
  api/         Rails 8 monolithe (API, agent, MCP, audit)
  web/         Vue 3 + Vite (frontend statique)
  scanner/     Workers Go (binaires statiques, consomment good_jobs)
packages/
  job-schema/  Schemas JSON canoniques echanges Rails <-> Go
ops/
  postgres/    Image Postgres dev (Postgres 16 + TimescaleDB + pgvector + Apache AGE)
docs/
openspec/      Specs et changes en cours (source de verite)
scripts/       Outillage CI (linter de stack, etc.)
```

## Stack figee

Voir `openspec/project.md` section *Stack*.

## Bootstrap dev local

```sh
bin/setup     # construit l'image Postgres dev et la demarre
bin/test      # lance les suites de toutes les sous-apps (skip celles non encore bootstrapees)
```

## Statut

Bootstrap en cours par iterations OpenSpec :
1. `init-reconaut-platform` - perimetre fondateur
2. `add-tech-stack` - layout monorepo + bootstrap Rails / Vue / Go (en cours)
3. `add-graph-retrieval` - couche graphe AGE + retrieval hybride

Note de recherche : `openspec/research/graph-rag.md`.

## Documentation

- [`docs/architecture/graph-templates.md`](docs/architecture/graph-templates.md)
  - comment ajouter un template Cypher au catalogue de l'agent.
- [`docs/architecture/age-limits.md`](docs/architecture/age-limits.md)
  - limites d'Apache AGE et politique de fallback.
- [`docs/architecture/scan-frontier.md`](docs/architecture/scan-frontier.md)
  - frontiere Rails <-> workers Go, schemas de message, ajout d'un
  nouveau type de scan.
- [`docs/architecture/worker-scaling.md`](docs/architecture/worker-scaling.md)
  - runbook : ajouter / retirer un worker Go en production.

## Licence

AGPL-3.0-only. Voir `openspec/project.md` section *Gouvernance et distribution*.
