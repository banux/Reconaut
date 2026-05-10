# Déploiement du site de documentation

Statut : **stable**.
Audience : mainteneur Reconaut qui configure le repo GitHub.

Ce document décrit la mise en place initiale du site de doc public sur GitHub Pages. C'est un setup **one-shot** par fork ; une fois fait, le workflow `.github/workflows/docs.yml` prend le relais à chaque push qui touche `docs/`.

## Prérequis

- Un repo GitHub avec push sur `main`.
- Permission **Settings → Pages** configurable (admin du repo).

## Activation GitHub Pages (manuelle, one-shot)

GitHub Pages exige une activation manuelle au niveau Settings — il n'y a pas d'API qui permette à un workflow de se l'activer lui-même au premier run.

1. Rendre une visite à **Settings → Pages** du repo.
2. Sous **Source**, sélectionner **Deploy from a branch**.
3. Sous **Branch**, sélectionner `gh-pages` / `(root)`.
4. Sauvegarder.

Au prochain push sur `main` qui touche la doc, le workflow `docs.yml` :

1. Régénère les pages auto (`mcp-tools.md`, `rest-routes.md`).
2. Vérifie qu'aucun diff n'est laissé (sinon échoue avec un message explicite).
3. Build `mkdocs build --strict` (échoue sur tout warning).
4. Pousse `site/` sur la branche `gh-pages`.
5. GitHub Pages détecte le push et publie sous `https://<owner>.github.io/<repo>/`.

## URL publique

Pour le repo upstream :

> [https://banux.github.io/Reconaut/](https://banux.github.io/Reconaut/)

Pour un fork, c'est `https://<fork-owner>.github.io/Reconaut/` (à condition que GitHub Pages soit aussi activé sur le fork).

## Mise à jour locale du site

Pour prévisualiser localement avant un push :

```sh
python -m venv .venv-docs && source .venv-docs/bin/activate
pip install -r docs/requirements-docs.txt
mkdocs serve   # http://127.0.0.1:8000 avec live reload
```

Pour régénérer les références automatiques :

```sh
cd apps/api && bundle exec ruby ../../scripts/gen_mcp_tools_reference.rb
cd .. && ruby scripts/gen_rest_reference.rb
```

Les fichiers `docs/reference/mcp-tools.md` et `docs/reference/rest-routes.md` sont **committed** dans le repo — c'est volontaire pour que le diff soit reviewable en PR. Le job CI `docs.yml` re-exécute la régénération et **échoue** si le résultat diverge du committed.

## Désactivation du site

Si tu veux désactiver le déploiement (sans supprimer la doc) :

1. **Settings → Pages → Source → None**.
2. Optionnel : commenter le step `Deploy to gh-pages` dans `.github/workflows/docs.yml`.

Les sources Markdown sous `docs/` restent navigables dans le repo GitHub (rendu par le viewer Markdown intégré).
