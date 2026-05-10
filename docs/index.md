# Reconaut

**Base de connaissance d'actifs internet pour agents IA, auto-hébergeable et scope-driven.**

Reconaut maintient un graphe d'actifs scopé par l'opérateur (CIDR, domaines, hôtes) que ses agents IA et ses autres outils consomment via **MCP HTTP+SSE**. Mono-user, AGPL-3.0, intégrable avec la stack sécurité existante (entrée : ingestion de scanners externes ; sortie : MCP + futurs webhooks).

## À qui ça s'adresse

- **Opérateur ASM auto-hébergé** qui veut centraliser l'inventaire de son périmètre internet sans dépendre d'un SaaS.
- **Équipes Red/Blue** qui ingèrent les résultats de leurs scanners (nmap, OpenVAS, Nuclei, Censys exports) dans une base unique requêtable.
- **Agents IA externes** (Claude SDK, OpenAI Assistants, agents maison) qui veulent un référentiel d'actifs accessible via MCP.

## Quickstart 5 minutes

Pré-requis : Docker, Ruby 3.4+, Go 1.23+.

```sh
git clone https://github.com/banux/Reconaut.git
cd Reconaut
docker compose up -d postgres
cd apps/api && bundle && bundle exec rails db:setup
RECONAUT_OPERATOR_PASSWORD=changeme bundle exec rails reconaut:set_password
bundle exec rails server
```

Dans un autre terminal :

```sh
cd apps/tui && go build -o reconautctl ./cmd/reconautctl
RECONAUT_URL=http://localhost:3000 RECONAUT_PASSWORD=changeme ./reconautctl login
./reconautctl scope add cidr 192.0.2.0/24
./reconautctl scan request tcp_probe ip 192.0.2.10
```

## Naviguer

- **[Positionnement](positioning/agent-knowledge-base.md)** — pourquoi Reconaut existe, ce qui le distingue d'un SaaS ASM ou d'un Shodan.
- **[Usage : déclarer son scope](usage/scope.md)** — frontière éthique du scope-driven, refus en dur hors scope.
- **[Architecture](architecture/mcp-first.md)** — MCP-first, frontière de scan, templates de graphe, limites AGE.
- **[Opérationnel](operating/responsibility-model.md)** — modèle de responsabilité opérateur, embedder pluggable, streaming agent_chat, exports MCP.
- **[Intégrations](integrations/external-scanners.md)** — pousser depuis nmap, nuclei, OpenVAS, Censys.
- **[Référence](reference/mcp-tools.md)** — liste exhaustive des outils MCP et des routes REST autorisées.
- **[ADR](adr/0001-license.md)** — décisions structurantes (licence AGPL).

## Repo & licence

- Source : [github.com/banux/Reconaut](https://github.com/banux/Reconaut)
- Licence : **AGPL-3.0-only** ([texte complet](https://www.gnu.org/licenses/agpl-3.0.txt))
- Spec & change tracking : [`openspec/`](https://github.com/banux/Reconaut/tree/main/openspec)
- Issues : [github.com/banux/Reconaut/issues](https://github.com/banux/Reconaut/issues)
