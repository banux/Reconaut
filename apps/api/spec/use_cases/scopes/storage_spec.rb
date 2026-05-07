# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/use_cases/scopes/storage"

RSpec.describe Scopes::Storage::InMemory do
  subject(:storage) { described_class.new }

  describe "#create" do
    it "cree un scope avec un id uuid" do
      scope = storage.create(kind: "domain", value: "example.fr")
      expect(scope.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(scope.kind).to eq("domain")
      expect(scope.value).to eq("example.fr")
      expect(scope.created_at).to match(/\A2\d{3}-\d{2}-\d{2}T/)
    end

    it "rejette un kind hors enum" do
      expect { storage.create(kind: "person", value: "alice") }
        .to raise_error(ArgumentError, "invalid_kind")
    end

    it "rejette une value vide ou que des espaces" do
      expect { storage.create(kind: "ip", value: "") }
        .to raise_error(ArgumentError, "value_required")
      expect { storage.create(kind: "ip", value: "   ") }
        .to raise_error(ArgumentError, "value_required")
    end

    it "trim la value" do
      scope = storage.create(kind: "ip", value: "  192.0.2.1  ")
      expect(scope.value).to eq("192.0.2.1")
    end
  end

  describe "#list / #delete" do
    it "ordonnance d'abord vide, puis liste apres create, puis delete retire" do
      expect(storage.list).to be_empty

      a = storage.create(kind: "domain", value: "a.fr")
      b = storage.create(kind: "ip", value: "192.0.2.2")

      ids = storage.list.map(&:id)
      expect(ids).to contain_exactly(a.id, b.id)

      removed = storage.delete(a.id)
      expect(removed.id).to eq(a.id)
      expect(storage.list.map(&:id)).to eq([b.id])
    end

    it "delete sur un id inconnu retourne nil sans lever" do
      expect(storage.delete("nope")).to be_nil
    end
  end

  describe "thread-safety" do
    it "100 creates concurrents -> tous presents" do
      threads = 10.times.map do |i|
        Thread.new do
          10.times do |j|
            storage.create(kind: "ip", value: "10.0.#{i}.#{j}")
          end
        end
      end
      threads.each(&:join)
      expect(storage.list.size).to eq(100)
    end
  end
end
