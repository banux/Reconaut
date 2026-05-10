# Tâches : add-doc-site

Checklist de la mise en place du site de doc public via MkDocs Material.

---

## 1. Configuration MkDocs

- [x] **1.1 `mkdocs.yml` à la racine du repo**
  - **Notes** : Configuration minimale :
    ```yaml
    site_name: Reconaut
    site_description: Base de connaissance d'actifs internet pour agents IA, scope-driven, AGPL-3.0
    site_url: https://banux.github.io/Reconaut/
    repo_url: https://github.com/banux/Reconaut
    repo_name: banux/Reconaut
    edit_uri: edit/main/docs/

    docs_dir: docs

    theme:
      name: material
      language: fr
      palette:
        - media: "(prefers-color-scheme: light)"
          scheme: default
          primary: indigo
          toggle: { icon: material/brightness-7, name: Mode sombre }
        - media: "(prefers-color-scheme: dark)"
          scheme: slate
          primary: indigo
          toggle: { icon: material/brightness-4, name: Mode clair }
      features:
        - navigation.sections
        - navigation.expand
        - navigation.top
        - search.suggest
        - content.code.copy
        - content.action.edit
      icon:
        repo: fontawesome/brands/github

    markdown_extensions:
      - admonition
      - pymdownx.details
      - pymdownx.superfences
      - pymdownx.tabbed: { alternate_style: true }
      - pymdownx.highlight: { anchor_linenums: true }
      - pymdownx.inlinehilite
      - tables
      - toc: { permalink: true }

    plugins:
      - search

    extra:
      generator: false # désactive la mention "Made with Material for MkDocs"

    nav:
      - Accueil: index.md
      - Positionnement:
          - Vue d'ensemble: positioning/agent-knowledge-base.md
      - Usage:
          - Déclarer son scope: usage/scope.md
      - Architecture:
          - Frontière de scan: architecture/scan-frontier.md
          - MCP-first: architecture/mcp-first.md
          - Bootstrap auth: architecture/auth-bootstrap.md
          - Templates de graphe: architecture/graph-templates.md
          - Limites AGE: architecture/age-limits.md
          - Worker scaling: architecture/worker-scaling.md
      - Opérationnel:
          - Modèle de responsabilité: operating/responsibility-model.md
          - Providers d'embedding: operating/embedder-providers.md
          - Streaming agent_chat: operating/agent-chat-streaming.md
          - Exports MCP: operating/mcp-exports.md
      - Intégrations:
          - Scanners externes: integrations/external-scanners.md
      - Référence:
          - Outils MCP: reference/mcp-tools.md
          - Routes REST: reference/rest-routes.md
      - ADR:
          - Choix de licence: adr/0001-license.md
    ```
  - **Test plan** : `mkdocs build --strict` passe sans warning depuis la racine du repo.

- [x] **1.2 `docs/requirements-docs.txt`**
  - **Notes** : Dépendances Python build-only :
    ```
    mkdocs==1.6.1
    mkdocs-material==9.5.49
    pymdown-extensions==10.14
    ```
    Versions épinglées pour reproductibilité.
  - **Test plan** : `pip install -r docs/requirements-docs.txt` réussit sur Python 3.11+ ; `mkdocs --version` retourne 1.6.1.

- [x] **1.3 `docs/index.md` page d'accueil**
  - **Notes** : Landing page extraite/réécrite à partir du `README.md` racine. Présente Reconaut en 5 sections : qu'est-ce que c'est, à qui ça s'adresse, quickstart 5 min, navigation vers les sections, liens externes (repo GitHub, AGPL).
  - **Test plan** : `grep -i "reconaut\|quickstart" docs/index.md` retourne ≥ 3 matches. Les liens internes `[...](positioning/...)` etc. résolvent.

---

## 2. Génération automatique des références

- [x] **2.1 `scripts/gen_mcp_tools_reference.rb`**
  - **Notes** : Script Ruby qui :
    1. Charge `Rails.application` minimal (juste pour booter `Mcp::ToolRegistry`).
    2. Appelle `Mcp::CoreTools.register_all!(...)` avec des stubs adaptés.
    3. Itère `Mcp::ToolRegistry.all` ; pour chaque tool, génère une section Markdown :
       - `## <name>`
       - Scopes requis : `read:hosts`, etc.
       - Schéma de params (depuis `tool.params_schema`) : type, contraintes, requis.
       - Exemple `curl` (POST `/mcp/tools/<name>`).
    4. Écrit `docs/reference/mcp-tools.md` (déterministe : ordre alphabétique des tools).
  - **Test plan** : `bundle exec ruby scripts/gen_mcp_tools_reference.rb && git diff --exit-code docs/reference/mcp-tools.md` retourne 0 (idempotent). Le fichier généré contient ≥ 12 sections (autant que de tools).

- [x] **2.2 `scripts/gen_rest_reference.rb`**
  - **Notes** : Script Ruby qui parse `config/routes.rb` (lecture du fichier comme texte, regex sur les déclarations `get/post/put/delete/patch`) et génère `docs/reference/rest-routes.md` listant les 4 familles : auth bootstrap, healthcheck, MCP tools, MCP exports. Pour chaque route : verbe HTTP, path, controller#action, exemple curl.
  - **Test plan** : Le fichier généré contient les 4 familles, ordre stable. `bundle exec ruby scripts/gen_rest_reference.rb && git diff --exit-code docs/reference/rest-routes.md` idempotent.

- [x] **2.3 Pages générées committed**
  - **Notes** : Lancer les deux scripts une fois pour produire `docs/reference/mcp-tools.md` et `docs/reference/rest-routes.md` ; commiter sous `add-doc-site`.
  - **Test plan** : Les fichiers existent et sont navigables depuis `mkdocs serve`.

---

## 3. Linter de cohérence des liens

- [x] **3.1 `scripts/check_doc_links.sh`**
  - **Notes** : Script bash qui scanne `docs/**/*.md`, extrait tous les liens relatifs `[label](relative/path.md)` et `[label](relative/path.md#anchor)`, vérifie que chaque cible existe (ou que l'anchor existe dans le fichier cible). Tolère les URLs absolues (https://). Ignore les blocs de code (entre ```...``` ou indentés à 4 espaces).
  - **Test plan** : Sur le tree actuel → exit 0. Test : injecter `[bad](../doesnt-exist.md)` dans un fichier → exit ≠ 0.

- [x] **3.2 `scripts/check_doc_links_test.sh`**
  - **Notes** : Tests du linter sur cas typiques : (a) état propre, (b) lien cassé, (c) lien vers anchor manquante, (d) cleanup.
  - **Test plan** : `bash scripts/check_doc_links_test.sh` retourne 0.

- [x] **3.3 Wiring CI**
  - **Notes** : Ajouter au job `stack-lint` dans `.github/workflows/ci.yml` :
    ```yaml
    - run: bash scripts/check_doc_links.sh
    - run: bash scripts/check_doc_links_test.sh
    ```
  - **Test plan** : Le job stack-lint passe vert avec les nouveaux steps.

---

## 4. CI workflow `docs.yml`

- [x] **4.1 `.github/workflows/docs.yml`**
  - **Notes** : Workflow GitHub Actions :
    ```yaml
    name: docs
    on:
      push:
        branches: [main]
        paths:
          - "docs/**"
          - "mkdocs.yml"
          - "scripts/gen_*.rb"
          - "apps/api/app/lib/mcp/**"
          - "config/routes.rb"
      workflow_dispatch:

    permissions:
      contents: write

    jobs:
      build-and-deploy:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - uses: ruby/setup-ruby@v1
            with: { ruby-version: 3.4, bundler-cache: true }
            working-directory: apps/api
          - uses: actions/setup-python@v5
            with: { python-version: 3.11 }
          - run: pip install -r docs/requirements-docs.txt
          - run: bundle exec ruby scripts/gen_mcp_tools_reference.rb
            working-directory: apps/api
          - run: bundle exec ruby scripts/gen_rest_reference.rb
            working-directory: apps/api
          - run: git diff --exit-code docs/reference/
            # Échoue si le contributeur a oublié de régénérer
          - run: mkdocs build --strict
          - uses: peaceiris/actions-gh-pages@v4
            if: github.ref == 'refs/heads/main'
            with:
              github_token: ${{ secrets.GITHUB_TOKEN }}
              publish_dir: ./site
    ```
  - **Test plan** : Workflow déclenché sur push `main` qui touche `docs/`. Vérifie que `mkdocs build --strict` passe et que le déploiement GitHub Pages se fait.

- [x] **4.2 Permissions GitHub Pages activées**
  - **Notes** : À configurer manuellement dans GitHub Settings > Pages : source = `gh-pages` branch. Documenter dans le proposal.
  - **Test plan** : Après le premier push qui déclenche le workflow, `https://banux.github.io/Reconaut/` répond 200 et affiche la page d'accueil.

---

## 5. Acceptance pour le change dans son ensemble

- [x] **5.1 `mkdocs build --strict` passe en local**
  - **Notes** : Procédure pour un contributeur :
    ```sh
    python -m venv .venv-docs && source .venv-docs/bin/activate
    pip install -r docs/requirements-docs.txt
    mkdocs build --strict
    ```
    Sortie code 0, répertoire `site/` généré.

- [x] **5.2 Aucune régression**
  - Toute la suite RSpec actuelle (534 examples avant ce change) reste verte. Tous les linters CI restent verts (y compris les nouveaux `check_doc_links.sh` et le diff sur `docs/reference/`).

- [x] **5.3 Pas d'analytics tiers dans le site rendu**
  - `grep -RiE "googletagmanager|google-analytics|mixpanel|segment|amplitude|posthog" site/` retourne 0 ligne après `mkdocs build`.

- [x] **5.4 Tick `init-reconaut-platform` §9.4**
  - Modifier `openspec/changes/init-reconaut-platform/tasks.md` pour cocher §9.4 avec un statut documentant : (a) MkDocs Material choisi, (b) référence MCP + REST auto-générée, (c) déploiement GitHub Pages, (d) `check_doc_links.sh` linter.
