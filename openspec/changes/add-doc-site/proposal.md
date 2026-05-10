# Change : add-doc-site

## Pourquoi

`init-reconaut-platform` §9.4 demande un *site de doc public* qui expose la référence API + la référence des outils MCP HTTP+SSE + des runbooks de déploiement. Aujourd'hui la documentation vit sous `docs/` (15+ fichiers Markdown organisés en `architecture/`, `operating/`, `integrations/`, `positioning/`, `usage/`, `adr/`) mais il n'y a **aucune surface publique navigable** : un opérateur potentiel doit cloner le repo et lire les `.md` dans son éditeur ; un agent IA externe qui veut découvrir les outils MCP n'a pas de référence consolidée.

Trois trous concrets que ce change ferme :

1. **Pas de surface web navigable.** Les fichiers `docs/*.md` ne sont rendus que par le viewer Markdown de GitHub — pas de search global, pas de sommaire, pas de mode sombre, pas de mobile-friendly, pas de version par release.
2. **Pas de référence MCP générée.** La liste des tools MCP (search_hosts, get_host, request_scan, list_scans, get_scan_status, agent_chat, ingest_scan_result, system_doctor, list_api_keys, revoke_api_key, list_scopes, add_scope, revoke_scope, export_report, submit_heartbeat) doit être maintenue à la main si elle existe quelque part. Or `Mcp::ToolRegistry.all` connaît déjà chaque tool avec son schéma de params, ses scopes et son nom — il faut juste générer la doc à partir de ce registre.
3. **Pas de référence des routes REST réduite.** Les routes `auth/sessions`, `auth/api_keys`, `healthz`, `mcp/*` sont les seules autorisées par `mcp-as-primary-entrypoint`. Il faut une page qui les liste explicitement, générée depuis `config/routes.rb`.

## Ce qui change

1. **Choix d'outil : MkDocs Material.** Sélectionné plutôt que Docusaurus pour : (a) config plus simple (1 fichier `mkdocs.yml` vs un projet Node entier), (b) build plus rapide (~5 s vs 30+ s pour Docusaurus en mode prod), (c) footprint Python uniquement au build — pas de Node.js dans la stack runtime ni de dépendance npm dans le repo, cohérent avec project.md *« Vue 3 + Rails 8 + Go »*, (d) thème Material out-of-the-box (search lunr, dark mode, mobile-first, navbar/sidebar). Adopté par FastAPI, pydantic, uv, ruff — c'est le standard de fait pour les projets OSS modernes hors écosystème JS.

2. **Structure** : `mkdocs.yml` à la racine du repo, navigation hiérarchique alignée sur les dossiers `docs/*` existants. Index `docs/index.md` créé à partir du `README.md` (extrait du quickstart + lien vers les sections).

3. **Génération automatique** :
   - **`scripts/gen_mcp_tools_reference.rb`** : script Ruby qui boote l'environnement minimal Rails, lit `Mcp::ToolRegistry.all`, et génère `docs/reference/mcp-tools.md` (une section par tool : nom, scope requis, schéma de params, exemple curl).
   - **`scripts/gen_rest_reference.rb`** : script qui parse `config/routes.rb` et génère `docs/reference/rest-routes.md` (la liste des 4 familles d'endpoints REST : auth bootstrap, healthcheck, MCP transport, MCP exports).
   - Les deux scripts produisent un Markdown stable et déterministe (pas de timestamp, ordre alphabétique). Ils sont appelés par le job CI avant `mkdocs build`.

4. **CI workflow** `.github/workflows/docs.yml` :
   - Trigger : push sur `main` qui touche `docs/**`, `mkdocs.yml`, `scripts/gen_*.rb`, `apps/api/app/lib/mcp/**`, `config/routes.rb`.
   - Steps : (a) régénère les pages auto, (b) `mkdocs build --strict` (échoue sur tout warning : lien cassé, fichier orphelin, anchor manquante), (c) déploie sur `gh-pages` via `peaceiris/actions-gh-pages`.
   - L'URL publique est `https://banux.github.io/Reconaut/`.

5. **Tests d'intégrité** :
   - Linter `scripts/check_doc_links.sh` : vérifie qu'aucun fichier `docs/*.md` ne référence un fichier inexistant via grep simple sur les liens relatifs `[...](path/to/file.md)`. Wired in CI stack-lint.
   - `mkdocs build --strict` exécuté en CI à chaque push touchant la doc — échoue sur warnings.
   - Les pages auto-générées sont versionnées (committed dans le repo) pour que le build CI soit reproductible et que les changements soient revus en PR.

6. **Pas d'analytics, pas de tracking, pas de CDN tiers**. Cohérent avec `init-reconaut-platform` §1.3. Le thème Material n'embarque pas de Google Analytics par défaut ; on désactive explicitement (`google_analytics: null` dans la config).

## Contraintes

- **MkDocs Material en build only.** Aucune dépendance Python ne pollue la stack runtime. `requirements-docs.txt` vit sous `docs/` (à côté de `mkdocs.yml`) et n'est consommé que par le job CI docs et par les contributeurs qui veulent prévisualiser localement.
- **`check_stack.sh` reste vert.** Le linter rejette `*.py`, `pyproject.toml`, `uv.lock`, `Cargo.toml`, `Cargo.lock`. MkDocs n'introduit aucun de ces fichiers dans le repo — la config est en YAML, le contenu en Markdown, les déps en `requirements-docs.txt` (chaîne `pip install` côté CI). Pas de violation.
- **Pas d'analytics tiers.** Cohérent avec `init-reconaut-platform` §1.3 (`check_stack.sh` rejette mixpanel/segment/amplitude/posthog/plausible/matomo). Le thème Material désactive Google Analytics explicitement.
- **Pas de tracking côté client.** Le site rendu doit être servable depuis un origin local (file://) sans JavaScript externe. Les assets (CSS, JS, fonts, icônes) sont vendorisés par mkdocs-material, pas pulled depuis un CDN.
- **AGPL clean.** mkdocs-material est sous MIT (compatible AGPL). Les dépendances transitives (Pygments, MarkdownExtensions) sont sous BSD/MIT. Aucune licence non-OSI.
- **Pages auto-générées committed.** Pas de magie en CI : le script qui génère `docs/reference/mcp-tools.md` doit être ré-exécuté localement avant chaque PR qui change la registry. La CI exécute aussi le script et échoue si le fichier committed diverge (`git diff --exit-code docs/reference/`).
- **Versioning différé.** v1 sert un seul site `latest`. Pas de `v0.1`, `v0.2` separately. Quand Reconaut atteindra une release stable (1.0), `add-doc-versioning` introduira `mike` (le tool MkDocs de versioning).
- **Search lunr (offline)**. Pas d'Algolia. Lunr.js indexe le contenu au build, le client cherche localement dans le navigateur. Cohérent avec le principe « zéro outbound ».

## Non-objectifs (hors scope de ce change)

- **Versioning multi-release** (mike) — relève de `add-doc-versioning` quand Reconaut atteindra 1.0.
- **i18n / traductions** — la doc reste en français pour v1 (cohérent avec le code et les commits). Une version anglaise serait un effort communautaire (`add-doc-i18n` futur).
- **Algolia / search hosted** — lunr local suffit pour < 100 pages.
- **PDF export** — un opérateur peut imprimer les pages depuis le navigateur ; PDF dédié n'apporte pas de valeur.
- **Doc API auto-générée style Swagger** — les routes REST sont au nombre de 5, les outils MCP au nombre de 15. Une référence Markdown générée par script suffit. Swagger ajouterait un YAML OpenAPI à maintenir et une UI lourde pour 5 routes.
- **Custom theme** — Material est utilisé tel quel avec quelques overrides CSS minimaux (nom, logo). Un theme custom est un projet de plusieurs jours sans bénéfice fonctionnel.
- **Comments / discussions sur les pages** — pas de Disqus, pas de giscus en v1.
- **Build statique avec une autre lib** (Hugo, Eleventy, Astro) — comparé, MkDocs est le plus simple pour un projet à 95% Markdown.

## Décisions prises

1. **MkDocs Material plutôt que Docusaurus**. Rationale détaillé ci-dessus : config plus simple, pas de Node dans la stack runtime, thème de référence pour les projets OSS Python-adjacent. Docusaurus a sa place pour les sites avec beaucoup de composants React (changelog interactifs, démos live) — ce n'est pas notre cas.
2. **Pages auto-générées committed**. Plus simple à reviewer (`git diff` sur la PR), build CI reproductible, pas besoin de booter Rails au moment du `mkdocs build`. Le script de génération peut être ré-exécuté à la main par tout contributeur.
3. **Déploiement GitHub Pages via `peaceiris/actions-gh-pages`**. Action GitHub OSS éprouvée (10k+ utilisateurs). Pas besoin de gérer un serveur HTTP dédié.
4. **`mkdocs build --strict`** en CI. Force la chaîne complète à être verte (pas de lien cassé, pas de fichier orphelin) — sans ce flag, MkDocs warn sans échouer, ce qui laisse passer des régressions.
5. **Search via lunr.js (offline)**. Pas de tracking, pas d'outbound, pas de coût d'infrastructure. Les ~50 pages de Reconaut tiennent dans un index lunr de < 1 MB.
6. **`requirements-docs.txt` sous `docs/`**. Sépare cleanement les déps de build doc des autres. `pip install -r docs/requirements-docs.txt` dans le job CI ; les contributeurs qui veulent build local font la même chose dans un venv.

## Différé (non bloquant, parqué pour plus tard)

- **`add-doc-versioning`** : `mike` pour servir v1.0 / v1.1 / latest sur le même site.
- **`add-doc-i18n`** : version anglaise (et autres) via `mkdocs-static-i18n`.
- **`add-doc-search-algolia`** : si lunr devient lent à 500+ pages.
- **`add-changelog-page`** : page Changelog auto-générée depuis `git log` (avec `git-cliff` ou similaire).
- **`add-doc-comments`** : giscus (commentaires GitHub-backed) pour discussions par page.
- **`add-doc-pdf-export`** : `mkdocs-with-pdf` pour générer un PDF unique téléchargeable.
