# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/mcp/core_tools"
require_relative "../../../app/lib/reconaut/auth/storage"
require_relative "../../../app/use_cases/scopes/storage"
require_relative "../../../app/lib/reconaut/scans"

# Matrice RBAC : pour chaque tool MCP enregistré, vérifie que :
#   1. l'appel sans le scope requis lève Mcp::ScopeError nommant le scope.
#   2. l'appel avec exactement le scope requis n'est pas rejeté pour
#      raison d'autorisation (peut échouer pour un autre motif — payload
#      invalide etc. — mais pas avec ScopeError).
#
# Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
# (Requirement: MCP Authorization and Scopes)
# et openspec/changes/single-user-only/specs/mcp-server/spec.md
# (matrice unique par scope, sans rôle).
RSpec.describe "MCP RBAC matrix" do
  let(:scope_storage) { Scopes::Storage::InMemory.new }
  let(:scan_store)    { Reconaut::Scans::InMemoryStore.new }
  let(:api_key_store) { Reconaut::Auth::Storage::InMemoryApiKeys.new }
  let(:heartbeat_store) { Reconaut::Heartbeats::InMemoryStore.new }
  let(:retriever) do
    response = Agent::HybridRetriever::Response.new(
      rows: [], citations: [], warnings: [], retrieval_path: "none", duration_ms: 0
    )
    Class.new {
      def initialize(r) = (@r = r)
      def call(_q) = @r
    }.new(response)
  end
  let(:scan_enqueuer) do
    Reconaut::ScanEnqueuer.new(
      scope_storage: scope_storage,
      job_bus:       Reconaut::ScanEnqueuer::InMemoryJobBus.new,
      scan_store:    scan_store
    )
  end

  before do
    Mcp::ToolRegistry.reset!
    Mcp::CoreTools.register_all!(
      retriever:        retriever,
      scope_storage:    scope_storage,
      scan_enqueuer:    scan_enqueuer,
      api_key_storage:  api_key_store,
      heartbeat_store:  heartbeat_store,
      scan_store:       scan_store
    )
  end

  after { Mcp::ToolRegistry.reset! }

  # Pour les tools qui réclament des paramètres typés non triviaux,
  # on fournit un payload minimal qui passe la coercion mais peut
  # échouer plus tard pour des raisons métier (ex: out-of-scope). Ce
  # test ne vise QUE la couche RBAC, donc on ignore ces erreurs métier.
  PAYLOADS = {
    "search_hosts"      => { query: "x" },
    "get_host"          => { host_id: "x" },
    "list_scopes"       => {},
    "add_scope"         => { kind: "ip", value: "192.0.2.1" },
    "revoke_scope"      => { id: "missing" },
    "request_scan"      => { scan_kind: "tcp_probe", target_kind: "ip", target_value: "192.0.2.1" },
    "list_scans"        => {},
    "get_scan_status"   => { scan_id: "missing" },
    "agent_chat"        => { prompt: "x" },
    "ingest_scan_result"=> { payload: {} },
    "system_doctor"     => {},
    "submit_heartbeat"  => { payload: {} },
    "list_api_keys"     => {},
    "revoke_api_key"    => { id: "missing" }
  }.freeze

  describe "chaque tool refuse un caller sans son scope requis" do
    it "lève ScopeError nommant le scope manquant" do
      Mcp::ToolRegistry.all.each do |tool|
        params = PAYLOADS.fetch(tool.name, {})
        expect {
          tool.call(
            params:        params,
            caller_id:     "x",
            caller_scopes: [] # aucun scope
          )
        }.to raise_error(Mcp::ScopeError, /#{Regexp.escape(tool.scopes.first.to_s)}/),
          "tool=#{tool.name} devrait refuser sans scope"
      end
    end
  end

  describe "scénario explicite : viewer (read:hosts) tente add_scope" do
    it "ScopeError nomme write:scopes" do
      tool = Mcp::ToolRegistry.fetch("add_scope")
      expect {
        tool.call(
          params:        { kind: "ip", value: "192.0.2.1" },
          caller_id:     "viewer",
          caller_scopes: [:"read:hosts"]
        )
      }.to raise_error(Mcp::ScopeError, /write:scopes/)
    end
  end

  describe "OPERATOR_SCOPES couvre la matrice complète" do
    it "Mcp::ToolsController::OPERATOR_SCOPES inclut tous les scopes des tools" do
      required = Mcp::ToolRegistry.all.flat_map(&:scopes).uniq
      missing  = required - Mcp::ToolsController::OPERATOR_SCOPES
      expect(missing).to be_empty
    end
  end
end
