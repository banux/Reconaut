# Reconaut

**Base de connaissance d'actifs internet pour agents IA, auto-hebergeable et
scope-driven.** Reconaut maintient un graphe d'actifs scope par l'operateur
(CIDR, domaines, hotes) que ses agents IA et ses autres outils consomment via
**MCP HTTP+SSE**. Mono-user, AGPL-3.0, integrable avec la stack securite
existante (entree : ingestion de scanners externes ; sortie : MCP + futurs
webhooks).

Voir [`openspec/project.md`](openspec/project.md) pour le positionnement
complet, le modele de menace et la stack figee. Voir
[`docs/integrations/external-scanners.md`](docs/integrations/external-scanners.md)
pour pousser des resultats depuis nmap, nuclei et autres scanners tiers.

## Quickstart (5 minutes)

Pre-requis : Docker, Ruby 3.4+, Go 1.23+. Pas de Node — la SPA Vue a
ete retiree au profit de la TUI Go `reconautctl`.

```sh
git clone https://github.com/banux/Reconaut.git
cd Reconaut

# 1. Bootstrap : demarre Postgres + bundle install + go mod download.
bin/setup

# 2. Poser le password de l'opérateur unique (mono-user). Idempotent :
#    refuse si un user existe déjà.
RECONAUT_OPERATOR_PASSWORD='changez-moi' \
  (cd apps/api && bundle exec rails reconaut:set_password)
# -> imprime { user, api_key } : NOTEZ l'api_key.token, plus jamais consultable.

# 3. Lancer l'environnement de dev complet : Postgres + Rails + 6 scanners.
bin/dev
# -> http://localhost:3000/healthz
#    Ctrl-C pour stopper. Voir `bin/dev --help` pour les options
#    (--no-scanners, --no-rails, --postgres-only, --real-db).

# 4. (autre terminal) Construire et logguer la TUI operateur.
(cd apps/tui && go build ./cmd/reconautctl)
RECONAUT_URL=http://localhost:3000 RECONAUT_PASSWORD='changez-moi' \
  apps/tui/reconautctl login
# -> stocke la cle API dans $XDG_CONFIG_HOME/reconaut/credentials (0600).

# 5. Lancer les tests.
bin/test
```

## Bootstrap d'une instance auto-hebergee

Reconaut est concu pour tourner **100 % en reseau prive** avec l'embedder local
par defaut. Aucune cle API externe n'est requise pour faire fonctionner le
produit. Si vous voulez un embedder plus performant :

```sh
# Ollama (sidecar local recommande)
export RECONAUT_EMBEDDER_PROVIDER=ollama
export RECONAUT_EMBEDDER_OLLAMA_URL=http://localhost:11434
export RECONAUT_EMBEDDER_OLLAMA_MODEL=nomic-embed-text

# Mistral (API EU, optionnel)
export RECONAUT_EMBEDDER_PROVIDER=mistral
export RECONAUT_EMBEDDER_MISTRAL_API_KEY=...

# OpenAI-compatible (LM Studio, vLLM, llama.cpp server, LiteLLM, ...)
export RECONAUT_EMBEDDER_PROVIDER=openai-compatible
export RECONAUT_EMBEDDER_OPENAI_BASE_URL=http://lm-studio:1234
export RECONAUT_EMBEDDER_OPENAI_API_KEY=...
export RECONAUT_EMBEDDER_OPENAI_MODEL=nomic-embed
```

Self-check d'une instance : `bin/rails reconaut:doctor` imprime un rapport
JSON sur l'extension AGE, la region, le retard de projection graphe, le role
graph-reader et l'eventuelle dependance externe.

## Layout monorepo

```
apps/
  api/         Rails 8 monolithe (API, agent, MCP, audit, auth locale)
  tui/         Binaire Go reconautctl (TUI bubbletea, client MCP HTTP+SSE)
  scanner/     Workers Go specialises par scan_kind (cmd/scanner-<kind>/)
packages/
  job-schema/  Schemas JSON canoniques echanges Rails <-> Go
ops/
  postgres/    Image Postgres dev (Postgres 16 + TimescaleDB + pgvector + Apache AGE)
docs/          Architecture, runbooks, ADR
openspec/      Specs et changes en cours (source de verite)
scripts/       Outillage CI (linter de stack, etc.)
```

## Stack figee

- **Frontend** : binaire Go `reconautctl` (TUI bubbletea/Charm). Pas de
  SPA web. Le binaire consomme MCP HTTP+SSE pour les operations metier.
- **Backend** : Rails 8 monolithe (API, agent conversationnel, journal
  d'audit, serveur MCP HTTP+SSE) en un seul process.
- **Workers de scan** : Go (binaires statiques separes du process Rails).
  Communication Rails <-> Go via la table `good_jobs` Postgres uniquement.
- **File de jobs** : GoodJob (Postgres). **Pas de broker externe** (pas de
  Redis / RabbitMQ / NATS / Kafka).
- **Stockage** : Postgres unique avec TimescaleDB (timeseries),
  pgvector (semantique), Apache AGE (graphe d'actifs). **Pas de stockage
  objet** : exports en filesystem ou blobs Postgres.
- **Embeddings** : interface pluggable (local / Ollama / Mistral /
  OpenAI-compatible) selectionnable par variable d'environnement.
- **Auth** : local-first (Argon2id + cles API hashees). OIDC activable en
  parallele.
- **MCP** : transport HTTP+SSE uniquement (stdio non livre).

Detail complet : [`openspec/project.md`](openspec/project.md).

## Documentation

- [`docs/positioning/agent-knowledge-base.md`](docs/positioning/agent-knowledge-base.md)
  - vision produit : Reconaut = base de connaissance pour agents IA,
    composant de la stack securite (entree + sortie MCP).
- [`docs/adr/0001-license.md`](docs/adr/0001-license.md)
  - decision AGPL-3.0-only et alternatives ecartees.
- [`docs/architecture/mcp-first.md`](docs/architecture/mcp-first.md)
  - MCP comme canal d'entree principal : pourquoi, controllers REST
    restants, comment porter une feature en outil MCP.
- [`docs/architecture/auth-bootstrap.md`](docs/architecture/auth-bootstrap.md)
  - pourquoi les routes /auth/* restent REST (oeuf et poule de la cle API).
- [`docs/architecture/graph-templates.md`](docs/architecture/graph-templates.md)
  - comment ajouter un template Cypher au catalogue de l'agent.
- [`docs/architecture/age-limits.md`](docs/architecture/age-limits.md)
  - limites d'Apache AGE et politique de fallback.
- [`docs/architecture/scan-frontier.md`](docs/architecture/scan-frontier.md)
  - frontiere Rails <-> workers Go, schemas de message, ajout d'un
  nouveau type de scan.
- [`docs/architecture/worker-scaling.md`](docs/architecture/worker-scaling.md)
  - runbook : ajouter / retirer un worker Go en production.
- [`docs/operating/responsibility-model.md`](docs/operating/responsibility-model.md)
  - modele de responsabilite operateur / Reconaut / fournisseurs externes ;
    audit append-only, erase by target, etiquette de residence.
- [`docs/usage/scope.md`](docs/usage/scope.md)
  - declarer son scope, ce qui se passe quand une cible est hors scope.

## Statut

Bootstrap en cours par iterations OpenSpec :

1. `init-reconaut-platform` - perimetre fondateur (auth, scan, MCP)
2. `add-tech-stack` - layout monorepo + bootstrap Rails / Go
3. `add-graph-retrieval` - couche graphe AGE + retrieval hybride
4. `drop-gdpr-framing` - retire le cadre RGPD (Reconaut ne stocke pas de PII)

Note de recherche : [`openspec/research/graph-rag.md`](openspec/research/graph-rag.md).

## Licence

**AGPL-3.0-only**. Texte integral : [`LICENSE`](LICENSE). Decision : voir
[`docs/adr/0001-license.md`](docs/adr/0001-license.md).

## Telemetrie

Reconaut **n'envoie aucune donnee au projet**. Aucun client d'analytics tiers
(Mixpanel, Segment, Amplitude, PostHog, Plausible server SDK, Matomo) n'est
embarque, et le linter de stack le verifie en CI. L'instrumentation
OpenTelemetry interne peut etre exposee si l'operateur configure
`OTEL_EXPORTER_OTLP_ENDPOINT` vers son propre collecteur.
