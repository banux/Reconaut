# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Génère `docs/reference/rest-routes.md` à partir de `config/routes.rb`.
#
# Cf. openspec/changes/add-doc-site/specs/open-source-governance/spec.md
#   -> Requirement: Public Documentation Site (auto-generated REST reference)
#
# Le script lit `apps/api/config/routes.rb` comme texte pur (pas de
# boot Rails — plus rapide et indépendant). Il extrait les déclarations
# get/post/delete et les classe en 4 familles cohérentes avec
# `mcp-as-primary-entrypoint` :
#
#   1. Auth bootstrap (/auth/sessions, /auth/api_keys)
#   2. Healthcheck (/healthz, /up)
#   3. MCP tools (/mcp/tools, /mcp/tools/:tool_name)
#   4. MCP exports (/mcp/exports/:id)
#
# Sortie déterministe (ordre des familles fixé, ordre des routes
# par famille fixé). Le job CI re-exécute et échoue si le diff n'est
# pas vide.

require "fileutils"

routes_path = File.expand_path("../apps/api/config/routes.rb", __dir__)
raw         = File.read(routes_path)

# Extrait les déclarations sous forme `verb "/path", to: "controller#action"`.
# On ignore les `scope ... do` (no route attaché).
ROUTE_RE = /^\s*(get|post|put|delete|patch)\s+(?:"([^"]+)"|(\S+?))\s*(?:=>|,\s*to:)\s*"([^"]+)"/
SCOPE_RE = /^\s*scope\s+"([^"]+)"\s+do/

scopes_stack = []
routes = []

raw.each_line do |line|
  if (m = SCOPE_RE.match(line))
    scopes_stack << m[1]
  elsif line.match?(/^\s*end\s*$/) && !scopes_stack.empty?
    scopes_stack.pop
  elsif (m = ROUTE_RE.match(line))
    verb   = m[1].upcase
    path   = m[2] || m[3]
    target = m[4]
    full   = scopes_stack.join("") + path
    full   = "/" + full unless full.start_with?("/")
    routes << { verb: verb, path: full, target: target }
  end
end

# Classe en familles
def family_for(route)
  p = route[:path]
  case
  when p.start_with?("/auth/")    then :auth
  when p == "/healthz" || p == "/up" || p == "up" then :health
  when p.start_with?("/mcp/exports") then :mcp_exports
  when p.start_with?("/mcp/")     then :mcp_tools
  else :other
  end
end

grouped = Hash.new { |h, k| h[k] = [] }
routes.each { |r| grouped[family_for(r)] << r }
grouped.each_value { |list| list.sort_by! { |r| [r[:path], r[:verb]] } }

def render_family(title, description, routes)
  return "" if routes.empty?

  lines = ["## #{title}", "", description, "", "| Verbe | Path | Controller#action | Exemple |", "|-------|------|-------------------|---------|"]
  routes.each do |r|
    example = case r[:verb]
              when "GET"
                "`curl -i http://localhost:3000#{r[:path]}`"
              when "POST"
                "`curl -X POST http://localhost:3000#{r[:path]} -d '...'`"
              else
                "`curl -X #{r[:verb]} http://localhost:3000#{r[:path]}`"
              end
    lines << "| `#{r[:verb]}` | `#{r[:path]}` | `#{r[:target]}` | #{example} |"
  end
  lines << ""
  lines.join("\n")
end

content = <<~MD
  # Référence des routes REST

  Cette page est **générée automatiquement** par
  `scripts/gen_rest_reference.rb` à partir de `apps/api/config/routes.rb`.
  Ne pas éditer à la main — toute modification sera écrasée à la
  prochaine régénération.

  Reconaut expose une **API REST volontairement minimaliste** : seules
  les 4 familles ci-dessous sont autorisées (cf.
  [`mcp-as-primary-entrypoint`](../../openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md)
  *Requirement: REST API Reduced to Bootstrap, Health and MCP Transport*).
  Toute nouvelle route hors de ces familles est rejetée par le linter
  CI [`scripts/check_rest_allowlist.sh`](https://github.com/banux/Reconaut/blob/main/scripts/check_rest_allowlist.sh).

  Pour les opérations métier (scope, scan, agent, exports), utiliser les
  [outils MCP](mcp-tools.md) sur `POST /mcp/tools/<name>`.

  ---

  #{render_family("Auth bootstrap", "Endpoints REST nécessaires pour obtenir une clé API initiale (œuf et poule). Une fois la clé en main, les opérations passent par MCP.", grouped[:auth])}

  #{render_family("Healthcheck", "Probe non authentifié, dédié aux load balancers, k8s et probes Prometheus blackbox.", grouped[:health])}

  #{render_family("MCP tools", "Surface canonique des outils Reconaut exposés via JSON-RPC HTTP+SSE. Voir [Référence des outils MCP](mcp-tools.md) pour le détail des paramètres.", grouped[:mcp_tools])}

  #{render_family("MCP exports", "Téléchargement one-shot des exports générés par le tool MCP `export_report` (URL signée HMAC-SHA256, TTL 1h, cf. [Exports MCP](../operating/mcp-exports.md)).", grouped[:mcp_exports])}
MD

# Nettoie les blocs vides éventuels (familles sans route)
content = content.gsub(/\n{3,}/, "\n\n").strip + "\n"

dest = File.expand_path("../docs/reference/rest-routes.md", __dir__)
FileUtils.mkdir_p(File.dirname(dest))
File.write(dest, content)
puts "wrote #{dest} (#{routes.size} routes across #{grouped.size} families)"
