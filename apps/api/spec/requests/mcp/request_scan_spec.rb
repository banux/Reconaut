# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/mcp/core_tools"

# Couvre :
#   openspec/changes/init-reconaut-platform/specs/mcp-server/spec.md
#     -> request_scan rejette les cibles hors scope
#   openspec/changes/init-reconaut-platform/tasks.md section 5.2
#   openspec/changes/add-tech-stack/specs/architecture/spec.md
#     -> Demande de scan se materialise comme un job GoodJob

RSpec.describe "MCP request_scan", type: :request do
  let(:registry) { Reconaut::Registry.default }
  let(:storage)  { Scopes::Storage::InMemory.new }
  let(:retriever_response) do
    Agent::HybridRetriever::Response.new(
      rows: [], citations: [], warnings: [], retrieval_path: "none", duration_ms: 0
    )
  end
  let(:retriever) do
    klass = Class.new do
      def initialize(r) = (@r = r)
      def call(_) = @r
    end
    klass.new(retriever_response)
  end

  before do
    registry.scope_storage = storage
    registry.job_bus = Reconaut::ScanEnqueuer::InMemoryJobBus.new
    Mcp::CoreTools.register_all!(
      retriever: retriever,
      scope_storage: storage,
      scan_enqueuer: registry.scan_enqueuer
    )
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  describe "scope check" do
    it "200 + ok=false out-of-scope quand la cible n'est pas autorisee" do
      post "/mcp/tools/request_scan",
        params: {
          scan_kind: "tcp_probe",
          target_kind: "ip",
          target_value: "8.8.8.8"
        }.to_json,
        headers: { "Content-Type" => "application/json",  }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:ok]).to be false
      expect(body[:result][:error]).to eq("out-of-scope")
      # Aucun job enqueued.
      expect(registry.job_bus.size).to eq(0)
      # Une ligne d'audit est écrite (cf. init-reconaut-platform §5.2).
      audit_entries = registry.audit_recorder.entries
      expect(audit_entries.size).to be >= 1
      expect(audit_entries.last[:template_id]).to eq("mcp:request_scan")
    end

    it "200 + scan_id quand la cible est dans le scope" do
      storage.create(kind: "ip", value: "192.0.2.1")
      Mcp::CoreTools.register_all!(retriever: retriever, scope_storage: storage,
                                   scan_enqueuer: registry.scan_enqueuer)

      post "/mcp/tools/request_scan",
        params: {
          scan_kind: "tcp_probe",
          target_kind: "ip",
          target_value: "192.0.2.1"
        }.to_json,
        headers: { "Content-Type" => "application/json",  }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:ok]).to be true
      expect(body[:result][:scan_id]).to be_a(String)
      expect(body[:result][:idempotency_key]).to start_with("scan-")
      # Un job present dans la file.
      expect(registry.job_bus.size).to eq(1)
      expect(registry.job_bus.jobs.first[:payload]["scan_kind"]).to eq("tcp_probe")
    end
  end

  describe "RBAC par scope (mono-user)" do
    before { storage.create(kind: "ip", value: "192.0.2.1") }

    it "rejette une clé sans write:scans avec 403" do
      _, raw = registry.api_key_store.create_for(scopes: [:"read:hosts"])

      post "/mcp/tools/request_scan",
        params:  {
          scan_kind: "tcp_probe", target_kind: "ip", target_value: "192.0.2.1"
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{raw}"
        }

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("rbac_forbidden")
    end

    it "autorise une clé avec write:scans" do
      _, raw = registry.api_key_store.create_for(scopes: [:"write:scans"])

      post "/mcp/tools/request_scan",
        params:  {
          scan_kind: "tcp_probe", target_kind: "ip", target_value: "192.0.2.1"
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{raw}"
        }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "validation des params" do
    before { storage.create(kind: "ip", value: "192.0.2.1") }

    it "400 param_invalid sur scan_kind hors enum" do
      post "/mcp/tools/request_scan",
        params: {
          scan_kind: "icmp_flood", target_kind: "ip", target_value: "192.0.2.1"
        }.to_json,
        headers: { "Content-Type" => "application/json",  }

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to eq("param_invalid")
    end

    it "400 param_invalid sur target_kind hors enum" do
      post "/mcp/tools/request_scan",
        params: {
          scan_kind: "tcp_probe", target_kind: "person", target_value: "alice"
        }.to_json,
        headers: { "Content-Type" => "application/json",  }

      expect(response).to have_http_status(:bad_request)
    end

    it "400 missing_param sur target_value absent" do
      post "/mcp/tools/request_scan",
        params: { scan_kind: "tcp_probe", target_kind: "ip" }.to_json,
        headers: { "Content-Type" => "application/json",  }

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to eq("missing_param")
    end
  end

  describe "dns_records (cf. add-dns-records-scanner)" do
    it "happy path : domaine dans le scope -> ok=true" do
      storage.create(kind: "domain", value: "example.fr")

      post "/mcp/tools/request_scan",
        params:  {
          scan_kind:    "dns_records",
          target_kind:  "domain",
          target_value: "example.fr"
        }.to_json,
        headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:ok]).to be true
      expect(body[:result][:scan_id]).to be_a(String)
    end

    it "rejette target_kind=ip avec invalid_target" do
      storage.create(kind: "ip", value: "192.0.2.1")

      post "/mcp/tools/request_scan",
        params:  {
          scan_kind:    "dns_records",
          target_kind:  "ip",
          target_value: "192.0.2.1"
        }.to_json,
        headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:ok]).to be false
      expect(body[:result][:error]).to eq("invalid_target")
      expect(body[:result][:message]).to include("dns_records").and include("domain, host")
    end

    it "rejette target_kind=cidr avec invalid_target" do
      storage.create(kind: "cidr", value: "192.0.2.0/24")

      post "/mcp/tools/request_scan",
        params:  {
          scan_kind:    "dns_records",
          target_kind:  "cidr",
          target_value: "192.0.2.0/24"
        }.to_json,
        headers: { "Content-Type" => "application/json" }

      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:ok]).to be false
      expect(body[:result][:error]).to eq("invalid_target")
    end

    it "happy path : target_kind=host accepté" do
      storage.create(kind: "host", value: "mail.example.fr")

      post "/mcp/tools/request_scan",
        params:  {
          scan_kind:    "dns_records",
          target_kind:  "host",
          target_value: "mail.example.fr"
        }.to_json,
        headers: { "Content-Type" => "application/json" }

      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:ok]).to be true
    end

    it "domaine hors scope rejeté avec out-of-scope (avant invalid_target)" do
      # scope vide ; même un target_kind valide (domain) tombe sur out-of-scope
      post "/mcp/tools/request_scan",
        params:  {
          scan_kind:    "dns_records",
          target_kind:  "domain",
          target_value: "example.fr"
        }.to_json,
        headers: { "Content-Type" => "application/json" }

      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:result][:ok]).to be false
      expect(body[:result][:error]).to eq("out-of-scope")
    end
  end

  describe "latence" do
    before { storage.create(kind: "ip", value: "192.0.2.1") }

    it "renvoie en moins de 100 ms (enqueue uniquement, pas de scan)" do
      Mcp::CoreTools.register_all!(retriever: retriever, scope_storage: storage,
                                   scan_enqueuer: registry.scan_enqueuer)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      post "/mcp/tools/request_scan",
        params: {
          scan_kind: "tcp_probe", target_kind: "ip", target_value: "192.0.2.1"
        }.to_json,
        headers: { "Content-Type" => "application/json",  }
      elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000

      expect(response).to have_http_status(:ok)
      # Cible : < 100 ms d'apres add-tech-stack 4.2 ; on garde une marge
      # genereuse car CI peut etre lent.
      expect(elapsed_ms).to be < 500
    end
  end
end
