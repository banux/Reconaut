# frozen_string_literal: true

require "rails_helper"

# Spec backend ActiveRecord : tourne contre Storage::ActiveRecord*Users/ApiKeys
# via les mêmes shared examples que la version in-memory.
#
# Cf. openspec/changes/add-persistent-auth-storage/specs/platform/spec.md
#   -> Requirement: Backend de stockage auth interchangeable

RSpec.describe "Auth::Storage ActiveRecord adapters" do
  before(:all) do
    @skip = nil
    begin
      ActiveRecord::Base.connection.execute("SELECT 1")
      unless ActiveRecord::Base.connection.table_exists?(:api_keys) &&
             ActiveRecord::Base.connection.table_exists?(:users)
        @skip = "Tables api_keys/users absentes — lance `RAILS_ENV=test bundle exec rails db:migrate`"
      end
    rescue StandardError => e
      @skip = "DB indisponible : #{e.message}"
    end
  end

  before do
    skip(@skip) if @skip
    # Clean entre chaque example — pas de transactional fixtures
    # (cf. rails_helper.rb).
    Reconaut::Auth::ArApiKey.delete_all
    Reconaut::Auth::ArUser.delete_all
  end

  describe Reconaut::Auth::Storage::ActiveRecordUsers do
    let(:user_store) { described_class.new }

    include_examples "an auth users store"

    it "persiste réellement entre deux instances du store (cross-process simulation)" do
      u = user_store.create(email: "x@y.z", password_hash: "h")
      other_store = described_class.new
      expect(other_store.find(u.id).email).to eq("x@y.z")
    end
  end

  describe Reconaut::Auth::Storage::ActiveRecordApiKeys do
    # Précondition : un user en base pour servir de FK aux api_keys.
    let(:operator) do
      Reconaut::Auth::Storage::ActiveRecordUsers.new
                                                 .create(email: "operator@local", password_hash: "h" * 64)
    end

    let(:api_key_store) do
      operator # force la création
      described_class.new
    end

    include_examples "an auth api_keys store"

    it "user_id résolu vers l'UUID de l'unique opérateur" do
      record, _ = api_key_store.create_for
      expect(record.user_id).to eq(operator.id)
      expect(record.user_id).to match(/\A[0-9a-f-]{36}\z/i)
    end

    it "auto-bootstrappe un stub operator si aucun user n'existe (parité avec InMemoryApiKeys)" do
      Reconaut::Auth::ArApiKey.delete_all
      Reconaut::Auth::ArUser.delete_all
      _record, _raw = described_class.new.create_for
      expect(Reconaut::Auth::ArUser.count).to eq(1)
      expect(Reconaut::Auth::ArUser.first.email).to eq("operator-stub@local")
    end

    it "persiste réellement entre deux instances du store (cross-process simulation)" do
      record, raw = api_key_store.create_for
      other_store = described_class.new
      expect(other_store.find_by_token(raw).id).to eq(record.id)
    end

    it "token_hash en colonne ne contient pas le raw token" do
      _, raw = api_key_store.create_for
      ar = Reconaut::Auth::ArApiKey.first
      expect(ar.token_hash).not_to eq(raw)
      expect(ar.token_hash.length).to eq(64) # SHA-256 hex
    end
  end
end
