# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Reconaut
  module Embedder
    # Ollama : appelle un sidecar Ollama (HTTP REST sur localhost ou
    # reseau prive). API : POST /api/embeddings { model, prompt } ->
    # { embedding: [...] }.
    #
    # Cf. https://github.com/ollama/ollama/blob/main/docs/api.md
    class Ollama
      DEFAULT_TIMEOUT = 2.5

      def initialize(url:, model:, http_client: nil, timeout: DEFAULT_TIMEOUT)
        @url     = url.to_s.chomp("/")
        @model   = model
        @http    = http_client
        @timeout = timeout
      end

      attr_reader :model

      def provider = "ollama"

      def embed(texts:)
        texts.map { |t| call_one(t.to_s) }
      end

      def dim
        # Ollama ne publie pas la dim a priori. On la decouvre au premier
        # appel et on la cache. Si l'appelant veut la connaitre sans
        # passer par embed, on emet un embed sur ".".
        @dim ||= call_one(".").length
      end

      private

      def call_one(text)
        body = JSON.generate(model: @model, prompt: text)
        uri  = URI("#{@url}/api/embeddings")

        response =
          if @http
            @http.post(uri, body, "Content-Type" => "application/json")
          else
            Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                read_timeout: @timeout, open_timeout: @timeout) do |http|
              req = Net::HTTP::Post.new(uri.path)
              req["Content-Type"] = "application/json"
              req.body = body
              http.request(req)
            end
          end

        unless response.is_a?(Net::HTTPSuccess) || (response.respond_to?(:code) && response.code.to_i.between?(200, 299))
          raise UnavailableError, "ollama: HTTP #{response.code}"
        end

        parsed = JSON.parse(response.body)
        embedding = parsed["embedding"]
        raise UnavailableError, "ollama: missing embedding field" unless embedding.is_a?(Array)

        embedding
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
        raise UnavailableError, "ollama: #{e.class}: #{e.message}"
      end
    end
  end
end
