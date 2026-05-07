# apps/api

Rails 8 monolithe : API REST, agent conversationnel, journal d'audit, serveur MCP HTTP+SSE.

Specs de reference :
- `openspec/changes/add-tech-stack/specs/architecture/spec.md`
- `openspec/changes/init-reconaut-platform/specs/agent-interface/spec.md`
- `openspec/changes/init-reconaut-platform/specs/mcp-server/spec.md`

Statut : squelette Rails 8 API genere (iteration 2). Voir `bin/setup` racine
pour le bootstrap (Postgres dev image avec TimescaleDB + pgvector + AGE).

## Commandes utiles

```sh
bundle install
bin/rails db:prepare
bundle exec rspec
```
