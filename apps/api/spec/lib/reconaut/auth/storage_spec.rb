# frozen_string_literal: true

require "rails_helper"

# Spec backend in-memory : tourne contre les Storage::InMemory* via les
# shared examples partagés avec le backend ActiveRecord. Les assertions
# spécifiques au backend in-memory (user_id symbolique = OPERATOR_ID)
# vivent dans ce fichier.
#
# Cf. spec/support/shared_examples/auth_storage.rb

RSpec.describe Reconaut::Auth::Storage do
  describe Reconaut::Auth::Storage::InMemoryUsers do
    let(:user_store) { described_class.new }

    include_examples "an auth users store"
  end

  describe Reconaut::Auth::Storage::InMemoryApiKeys do
    let(:api_key_store) { described_class.new }

    include_examples "an auth api_keys store"

    it "user_id par défaut figé à OPERATOR_ID (mode mono-user, in-memory)" do
      record, _ = api_key_store.create_for
      expect(record.user_id).to eq(Reconaut::Auth::OPERATOR_ID)
    end
  end
end
