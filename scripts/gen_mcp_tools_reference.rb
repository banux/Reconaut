# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Génère `docs/reference/mcp-tools.md` à partir de `Mcp::ToolRegistry`.
#
# Cf. openspec/changes/add-doc-site/specs/open-source-governance/spec.md
#   -> Requirement: Public Documentation Site (auto-generated MCP reference)
#
# Le script boote l'environnement Rails minimal, enregistre tous les
# tools via `Mcp::CoreTools.register_all!` avec des stubs adéquats,
# puis itère `Mcp::ToolRegistry.all` (dans l'ordre alphabétique) et
# produit une section Markdown par tool.
#
# Sortie déterministe (pas de timestamp, ordre figé). Lancer avant
# chaque PR qui change `Mcp::CoreTools.register_all!` ; le job CI
# `docs.yml` re-exécute et échoue si le diff n'est pas vide
# (`git diff --exit-code docs/reference/`).

ENV["RAILS_ENV"] ||= "test"
require_relative "../apps/api/config/environment"

# Stubs pour register_all! — on n'invoque jamais ces collaborateurs,
# on lit juste les métadonnées (name, scopes, params_schema) déclarées.
class StubRetriever
  def call(_q) = nil
end

class StubScopeStorage
  def list = []
end

class StubScanEnqueuer
  def call(*) = nil
end

class StubScanStore
  def list(**) = []
  def find(_id) = nil
end

class StubApiKeyStorage
  def list = []
  def revoke!(_id) = nil
end

class StubIngestionRecorder
  def record(*) = nil
end

class StubHeartbeatStore
  def submit(*) = nil
  def latest = nil
end

Mcp::ToolRegistry.reset!
Mcp::CoreTools.register_all!(
  retriever:           StubRetriever.new,
  scope_storage:       StubScopeStorage.new,
  scan_enqueuer:       StubScanEnqueuer.new,
  scan_store:          StubScanStore.new,
  api_key_storage:     StubApiKeyStorage.new,
  ingestion_recorder:  StubIngestionRecorder.new,
  heartbeat_store:     StubHeartbeatStore.new
)

# ---- Markdown generation ---------------------------------------------------

def render_param(name, spec)
  type     = spec[:type] || "any"
  required = spec[:required] == false ? "optional" : "required"
  bounds   = []
  bounds << "min=#{spec[:min]}" if spec[:min]
  bounds << "max=#{spec[:max]}" if spec[:max]
  bounds << "min_length=#{spec[:min_length]}" if spec[:min_length]
  bounds << "max_length=#{spec[:max_length]}" if spec[:max_length]
  bounds << "default=#{spec[:default].inspect}" if spec.key?(:default)
  bounds_str = bounds.empty? ? "" : " (#{bounds.join(", ")})"
  "- `#{name}` : `#{type}`, **#{required}**#{bounds_str}"
end

def render_tool(tool)
  scopes_str = tool.scopes.map { |s| "`#{s}`" }.join(", ")
  scopes_str = "_(aucun scope requis)_" if scopes_str.empty?

  params_block = if tool.params_schema.empty?
                   "_Aucun paramètre._"
                 else
                   tool.params_schema.map { |n, s| render_param(n, s) }.join("\n")
                 end

  example_payload = example_for(tool)
  example = "```sh\n" \
            "curl -X POST http://localhost:3000/mcp/tools/#{tool.name} \\\n" \
            "  -H \"Authorization: Bearer $RECONAUT_API_KEY\" \\\n" \
            "  -H \"Content-Type: application/json\" \\\n" \
            "  -d '#{JSON.generate(example_payload)}'\n" \
            "```"

  <<~MD
    ## `#{tool.name}`

    **Scope MCP requis** : #{scopes_str}

    **Paramètres** :

    #{params_block}

    **Exemple** :

    #{example}
  MD
end

def example_for(tool)
  tool.params_schema.each_with_object({}) do |(name, spec), acc|
    next if spec[:required] == false

    acc[name] = sample_value_for(name, spec)
  end
end

def sample_value_for(name, spec)
  case spec[:type]
  when :integer then spec[:min] || spec[:default] || 1
  when :string  then sample_string_for(name, spec)
  when :hash    then {}
  when :enum    then Array(spec[:values]).first
  else "..."
  end
end

def sample_string_for(name, spec)
  case name.to_sym
  when :prompt        then "modbus exposés en France"
  when :query         then "modbus"
  when :scan_kind     then "tcp_probe"
  when :target_kind, :kind then "ip"
  when :target_value, :value then "192.0.2.10"
  when :host_id, :scan_id, :id then "00000000-0000-0000-0000-000000000000"
  when :format        then "json"
  else (spec[:min_length] ? "x" * spec[:min_length] : "...")
  end
end

require "json"

header = <<~MD
  # Référence des outils MCP

  Cette page est **générée automatiquement** par
  `scripts/gen_mcp_tools_reference.rb` à partir de `Mcp::ToolRegistry`.
  Ne pas éditer à la main — toute modification sera écrasée à la
  prochaine régénération.

  Tous les outils sont exposés sur `POST /mcp/tools/<name>` (cf.
  [routes REST](rest-routes.md)). L'authentification se fait via
  `Authorization: Bearer <api_key>` ; le scope de la clé doit couvrir
  les scopes requis listés ci-dessous.

MD

body = Mcp::ToolRegistry.all
                       .sort_by(&:name)
                       .map { |t| render_tool(t) }
                       .join("\n---\n\n")

content = header + body

dest = File.expand_path("../docs/reference/mcp-tools.md", __dir__)
FileUtils.mkdir_p(File.dirname(dest))
File.write(dest, content)
puts "wrote #{dest} (#{Mcp::ToolRegistry.all.size} tools)"
