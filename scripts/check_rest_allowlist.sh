#!/usr/bin/env bash
# scripts/check_rest_allowlist.sh - linter d'allowlist des routes REST
#
# Source de verite : openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
#                    Requirement: REST API Reduced to Bootstrap, Health and MCP Transport
#
# MCP HTTP+SSE est le canal d'entree principal. L'API REST est restreinte a :
#   - auth bootstrap : /auth/sessions, /auth/api_keys
#   - healthcheck : /healthz (et /up legacy Rails health route)
#   - transport MCP : /mcp/*
#
# Toute autre route REST DOIT figurer dans la zone de transition explicite
# (controllers depreciés en cours de migration vers MCP). L'introduction
# d'une nouvelle route hors allowlist ET hors zone de transition est rejetee.

set -euo pipefail

cd "$(dirname "$0")/.."

errors=0

fail() {
  echo "rest-route-not-allowed: $1" >&2
  errors=1
}

ROUTES_FILE="apps/api/config/routes.rb"

if [[ ! -f "$ROUTES_FILE" ]]; then
  echo "check_rest_allowlist: skip ($ROUTES_FILE absent)" >&2
  exit 0
fi

# --- Allowlist : chemins autorises hors MCP ----------------------------------
# Chaque entree est un pattern ERE matche par grep -E sur les declarations
# de route. La forme est volontairement liberale (matche le `to:` du
# controller) pour absorber les variations get/post/delete/etc.

ALLOWLIST_PATTERNS=(
  # auth bootstrap (canal REST par necessite : on n'a pas encore de cle API)
  '"/sessions"[[:space:]]*,[[:space:]]*to:[[:space:]]*"auth/sessions#'
  '"/sessions/:id"[[:space:]]*,[[:space:]]*to:[[:space:]]*"auth/sessions#'
  '"/api_keys/:id"[[:space:]]*,[[:space:]]*to:[[:space:]]*"auth/api_keys#'
  '"/api_keys"[[:space:]]*,[[:space:]]*to:[[:space:]]*"auth/api_keys#'
  # healthcheck
  '"up"[[:space:]]*=>[[:space:]]*"rails/health#'
  '"/healthz"'
  # transport MCP (toute route sous /mcp/* est autorisee — c'est le canal canonique)
  ',[[:space:]]*to:[[:space:]]*"mcp/'
)

# --- Zone de transition (depreciee, sera retiree par remove-rest-wrappers) --
# Vide depuis le change `single-user-only` : les controllers REST hérités
# (`Agent::ChatController`, `ScopesController`) ont été supprimés. Toute
# nouvelle route doit figurer dans l'ALLOWLIST_PATTERNS ci-dessus.
TRANSITION_PATTERNS=()

# Extrait les declarations de route (lignes "get/post/put/delete/patch" + "resources" + "match")
mapfile -t routes < <(
  grep -nE '^\s*(get|post|put|delete|patch|match|resources|scope|namespace)\b' "$ROUTES_FILE" \
    | grep -vE '^\s*#'
)

for line in "${routes[@]}"; do
  # On ne lint pas les `scope "/auth"` / `scope "/mcp"` blocks -- ils n'attachent pas
  # de route a eux seuls, leurs enfants le font.
  if [[ "$line" =~ ^[[:space:]]*[0-9]+:[[:space:]]*scope[[:space:]] ]]; then
    continue
  fi

  matched=0
  for allowed in "${ALLOWLIST_PATTERNS[@]}"; do
    if [[ "$line" =~ $allowed ]]; then
      matched=1
      break
    fi
  done

  if (( matched == 0 )); then
    for transition in "${TRANSITION_PATTERNS[@]}"; do
      if [[ "$line" =~ $transition ]]; then
        matched=1
        break
      fi
    done
  fi

  if (( matched == 0 )); then
    fail "$line"
  fi
done

if (( errors != 0 )); then
  echo "check_rest_allowlist: KO ($errors violations)" >&2
  echo "" >&2
  echo "Toute nouvelle feature operateur DOIT s'exposer comme outil MCP," >&2
  echo "pas comme route REST. Cf. openspec/changes/mcp-as-primary-entrypoint/." >&2
  echo "Si la nouvelle route est legitime (auth bootstrap / healthz / MCP transport)," >&2
  echo "ajoutez son pattern a ALLOWLIST_PATTERNS dans ce script." >&2
  exit 1
fi

echo "check_rest_allowlist: OK"
