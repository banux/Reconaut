# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /auth/sessions", type: :request do
  let(:registry) { Reconaut::Registry.default }

  before do
    registry.password_hasher = Reconaut::Auth::PasswordHasher::Plain.new
    registry.user_store.create(
      email: "owner@reconaut.local",
      password_hash: registry.password_hasher.hash("hunter2"),
      role: :owner
    )
  end

  after { Reconaut::Registry.reset! }

  it "201 + body contient le user (sans password_hash) et une cle API" do
    post "/auth/sessions",
      params: { email: "owner@reconaut.local", password: "hunter2" }.to_json,
      headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body, symbolize_names: true)
    expect(body[:user][:email]).to eq("owner@reconaut.local")
    expect(body[:user][:role]).to eq("owner")
    expect(body[:user]).not_to have_key(:password_hash)
    expect(body[:api_key][:token]).to be_a(String)
    expect(body[:api_key][:prefix]).to be_a(String)
  end

  it "401 invalid_credentials sur mauvais password" do
    post "/auth/sessions",
      params: { email: "owner@reconaut.local", password: "wrong" }.to_json,
      headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body)).to eq("error" => "invalid_credentials")
  end

  it "401 invalid_credentials sur user inexistant (sans leak)" do
    post "/auth/sessions",
      params: { email: "ghost@x.y", password: "x" }.to_json,
      headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end
end
