# Spec delta : open-source-governance

## ADDED Requirements

### Requirement: Public Documentation Site
La plateforme DOIT exposer un site de documentation public statique buildé via MkDocs Material à partir des fichiers Markdown sous `docs/`. Le site DOIT inclure une référence des outils MCP et des routes REST autorisées générée automatiquement à partir du code source.

Le site DOIT respecter ces contraintes :

- **Outil de build** : MkDocs Material (Python). Aucun runtime Node dans le repo, aucune dépendance Python en runtime.
- **Source** : tous les fichiers `docs/**/*.md` sont navigables via `mkdocs.yml`.
- **Pages auto-générées committed** : `docs/reference/mcp-tools.md` (généré par `scripts/gen_mcp_tools_reference.rb`) et `docs/reference/rest-routes.md` (généré par `scripts/gen_rest_reference.rb`). Le diff de ces fichiers est revu en PR.
- **Strict build** : le job CI exécute `mkdocs build --strict` ; tout warning (lien cassé, fichier orphelin, anchor manquante) fait échouer le build.
- **Pas d'analytics tiers** (Google Analytics, Plausible, Mixpanel, etc.) — cohérent avec `init-reconaut-platform` §1.3.
- **Search local** : index lunr.js généré au build, cherché côté client. Pas d'Algolia, pas d'API externe.
- **Pas de CDN tiers** : tous les assets (CSS, JS, fonts, icônes) sont vendorisés par mkdocs-material.
- **Déploiement** : GitHub Pages via `peaceiris/actions-gh-pages` sur push `main` qui touche `docs/**` ou `mkdocs.yml`.

#### Scenario: `mkdocs build --strict` passe en CI sans warning
- **GIVEN** un repo dans son état committé courant
- **WHEN** le job CI `docs.yml` exécute `pip install -r docs/requirements-docs.txt && mkdocs build --strict`
- **THEN** la commande sort en code 0 sans warning
- **AND** le répertoire `site/` est généré avec `index.html`, `reference/mcp-tools/index.html`, `reference/rest-routes/index.html`

#### Scenario: La référence MCP est cohérente avec `Mcp::ToolRegistry.all`
- **GIVEN** un nouvel outil MCP ajouté à `Mcp::CoreTools.register_all!`
- **WHEN** un contributeur lance `bundle exec ruby scripts/gen_mcp_tools_reference.rb` puis commite
- **THEN** `docs/reference/mcp-tools.md` contient une section pour le nouvel outil (nom, scope, params)
- **AND** le job CI échoue si un PR oublie de régénérer (vérifié par `git diff --exit-code docs/reference/`)

#### Scenario: La référence REST liste les 4 familles autorisées
- **GIVEN** `config/routes.rb` dans son état courant
- **WHEN** `bundle exec ruby scripts/gen_rest_reference.rb` est exécuté
- **THEN** `docs/reference/rest-routes.md` liste : `auth bootstrap` (sessions/api_keys), `healthcheck` (/healthz), `MCP transport` (/mcp/tools, /mcp/tools/:tool_name), `MCP exports` (/mcp/exports/:id)
- **AND** aucune autre famille n'apparaît (cohérent avec le linter `check_rest_allowlist.sh`)

#### Scenario: Pas d'analytics tiers dans le site rendu
- **GIVEN** le site buildé sous `site/`
- **WHEN** on grep le contenu HTML/JS pour des patterns analytics (`googletagmanager`, `google-analytics`, `mixpanel`, `segment`, `amplitude`, `posthog`)
- **THEN** **aucune** correspondance n'est trouvée

#### Scenario: Linter `check_doc_links.sh` rejette un lien cassé
- **GIVEN** un fichier `docs/architecture/foo.md` qui référence `[bar](../operating/non-existent.md)`
- **WHEN** `bash scripts/check_doc_links.sh` est exécuté
- **THEN** exit code ≠ 0 et le message d'erreur identifie le fichier source et la cible cassée
- **AND** le linter passe vert sur l'état actuel du repo

### Requirement: Documentation Build Idempotency
La génération des pages auto-générées DOIT être déterministe : exécuter `gen_mcp_tools_reference.rb` deux fois de suite sans changement de code source DOIT produire le **même** fichier (octet-pour-octet). Cohérent avec l'invariant *« CI reproductible »* de `init-reconaut-platform`.

#### Scenario: Régénération idempotente
- **GIVEN** un repo dans son état stable
- **WHEN** un contributeur exécute `bundle exec ruby scripts/gen_mcp_tools_reference.rb` deux fois consécutivement
- **THEN** `git diff docs/reference/mcp-tools.md` retourne vide après la deuxième exécution
- **AND** idem pour `gen_rest_reference.rb` et `docs/reference/rest-routes.md`

#### Scenario: Page non régénérée → CI échoue
- **GIVEN** un PR qui ajoute un nouvel outil MCP dans `core_tools.rb` mais oublie de régénérer `mcp-tools.md`
- **WHEN** le job CI `docs.yml` exécute la régénération puis `git diff --exit-code docs/reference/`
- **THEN** le job échoue avec un message indiquant que la doc auto-générée est out-of-sync
