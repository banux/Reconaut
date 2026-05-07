# frozen_string_literal: true

require "rails_helper"

# Couvre init-reconaut-platform 7.3 : "Test parametre par role exerce
# chaque endpoint et assure permis/refuse selon la matrice de role."
#
# Matrice de reference :
#
#                       viewer | analyst | mcp_client | admin | owner
#  GET    /scopes         200  |   200   |    200     |  200  |  200
#  POST   /scopes         403  |   403   |    403     |  201  |  201
#  DELETE /scopes/:id     403  |   403   |    403     |  204  |  204
#  POST   /agent/chat     403  |   200   |    200     |  200  |  200
#  POST   /mcp/tools/list_scopes (read:scopes)  -> 200 partout
#  POST   /mcp/tools/request_scan  (write:scans)
#                         403  |   403   |    200     |  200  |  200

RSpec.describe "RBAC role matrix", type: :request do
  ROLES = %i[viewer analyst mcp_client admin owner].freeze

  before do
    Reconaut::Registry.default.scope_storage = Scopes::Storage::InMemory.new
    Reconaut::Registry.default.audit_recorder = Agent::AuditRecorder::InMemoryRecorder.new
    Reconaut::Registry.default.job_bus = Reconaut::ScanEnqueuer::InMemoryJobBus.new

    response = Agent::HybridRetriever::Response.new(
      rows: [], citations: [], warnings: [],
      retrieval_path: "none", duration_ms: 0
    )
    Reconaut::Registry.default.hybrid_retriever = Class.new {
      def initialize(r) = (@r = r)
      def call(_) = @r
    }.new(response)

    Mcp::CoreTools.register_all!(
      retriever: Reconaut::Registry.default.hybrid_retriever,
      scope_storage: Reconaut::Registry.default.scope_storage,
      scan_enqueuer: Reconaut::Registry.default.scan_enqueuer
    )
    # Scope autorise pour que request_scan ne tombe pas en out-of-scope.
    Reconaut::Registry.default.scope_storage.create(kind: "ip", value: "192.0.2.1")
  end

  after do
    Mcp::ToolRegistry.reset!
    Reconaut::Registry.reset!
  end

  def headers_for(role)
    {
      "Content-Type" => "application/json",
      "X-Reconaut-Role" => role.to_s
    }
  end

  describe "GET /scopes (read autorise pour tous les roles)" do
    ROLES.each do |role|
      it "#{role} -> 200" do
        get "/scopes", headers: headers_for(role)
        expect(response).to have_http_status(:ok),
                             "role=#{role} got #{response.status}"
      end
    end
  end

  describe "POST /scopes (write : admin/owner uniquement)" do
    {
      viewer:     :forbidden,
      analyst:    :forbidden,
      mcp_client: :forbidden,
      admin:      :created,
      owner:      :created
    }.each do |role, expected|
      it "#{role} -> #{expected}" do
        post "/scopes",
          params: { kind: "domain", value: "example-#{role}.fr" }.to_json,
          headers: headers_for(role)
        expect(response).to have_http_status(expected),
                             "role=#{role} got #{response.status}"
      end
    end
  end

  describe "POST /agent/chat (analyst+ ; viewer refuse)" do
    {
      viewer:     :forbidden,
      analyst:    :ok,
      mcp_client: :ok,
      admin:      :ok,
      owner:      :ok
    }.each do |role, expected|
      it "#{role} -> #{expected}" do
        post "/agent/chat",
          params: { query: "hi" }.to_json,
          headers: headers_for(role)
        expect(response).to have_http_status(expected),
                             "role=#{role} got #{response.status}"
      end
    end
  end

  describe "POST /mcp/tools/request_scan (write:scans : mcp_client/admin/owner)" do
    {
      viewer:     :forbidden,
      analyst:    :forbidden,
      mcp_client: :ok,
      admin:      :ok,
      owner:      :ok
    }.each do |role, expected|
      it "#{role} -> #{expected}" do
        post "/mcp/tools/request_scan",
          params: {
            scan_kind: "tcp_probe",
            target_kind: "ip",
            target_value: "192.0.2.1"
          }.to_json,
          headers: headers_for(role)
        expect(response).to have_http_status(expected),
                             "role=#{role} got #{response.status}"
      end
    end
  end

  describe "POST /mcp/tools/list_scopes (read:scopes : tous les roles)" do
    ROLES.each do |role|
      it "#{role} -> 200" do
        post "/mcp/tools/list_scopes",
          params: {}.to_json,
          headers: headers_for(role)
        expect(response).to have_http_status(:ok),
                             "role=#{role} got #{response.status}"
      end
    end
  end
end
