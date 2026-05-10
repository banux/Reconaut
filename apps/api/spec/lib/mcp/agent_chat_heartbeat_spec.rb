# frozen_string_literal: true

require "rails_helper"
require "stringio"

# Cf. openspec/changes/add-agent-chat-streaming/specs/mcp-server/spec.md
#   -> Requirement: Agent Chat SSE Heartbeat

RSpec.describe Mcp::AgentChatHeartbeat do
  # FakeStream : IO en mémoire avec closed? settable.
  class FakeStream
    attr_reader :buffer
    def initialize
      @buffer = +""
      @closed = false
      @mutex  = Mutex.new
    end
    def write(s)
      raise IOError, "closed" if @closed

      @mutex.synchronize { @buffer << s }
    end
    def closed?
      @closed
    end
    def close
      @closed = true
    end
  end

  describe ".start" do
    it "interval_s=0 -> retourne nil, aucun thread" do
      expect(described_class.start(stream: FakeStream.new, interval_s: 0)).to be_nil
    end

    it "interval_s négatif -> retourne nil" do
      expect(described_class.start(stream: FakeStream.new, interval_s: -1)).to be_nil
    end

    it "émet au moins 2 pings sur 0.35s avec interval_s=0.1" do
      stream = FakeStream.new
      thread = described_class.start(stream: stream, interval_s: 0.1)
      sleep 0.35
      described_class.stop(thread)

      pings = stream.buffer.scan(/event: ping/).size
      expect(pings).to be >= 2
    end

    it "format SSE conforme : event: ping puis data: {} puis double newline" do
      stream = FakeStream.new
      thread = described_class.start(stream: stream, interval_s: 0.05)
      sleep 0.12
      described_class.stop(thread)

      expect(stream.buffer).to include("event: ping\ndata: {}\n\n")
    end

    it "sort silencieusement quand le stream est fermé" do
      stream = FakeStream.new
      thread = described_class.start(stream: stream, interval_s: 0.05)
      sleep 0.06
      stream.close
      sleep 0.1
      # Le thread doit être terminé proprement
      expect(thread.alive?).to be false
    end
  end

  describe ".stop" do
    it "tue le thread (status nil ou false)" do
      stream = FakeStream.new
      thread = described_class.start(stream: stream, interval_s: 5) # long sleep
      described_class.stop(thread)
      sleep 0.05
      expect(thread.alive?).to be false
    end

    it "no-op sur nil (heartbeat désactivé)" do
      expect { described_class.stop(nil) }.not_to raise_error
    end
  end
end
