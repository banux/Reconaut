# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Reconaut
  module Embedder
    # OpenAI-compatible : tout endpoint qui parle l'API OpenAI
    # `POST {base}/v1/embeddings { model, input: [...] }` ->
    # `{ data: [{ embedding: [...] }, ...] }`. Couvre par extension les
    # gateways (LM Studio, vLLM, llama.cpp server, LiteLLM, etc.)
    class OpenAICompatible
      DEFAULT_TIMEOUT = 2.5

      def initialize(base_url:, api_key:, model:, http_client: nil, timeout: DEFAULT_TIMEOUT)
        raise ArgumentError, "base_url required" if base_url.to_s.strip.empty?
        raise ArgumentError, "model required"    if model.to_s.strip.empty?

        @base_url = base_url.chomp("/")
        @api_key  = api_key
        @model    = model
        @http     = http_client
        @timeout  = timeout
      end

      attr_reader :model

      def provider = "openai-compatible"

      def embed(texts:)
        return [] if texts.empty?

        body = JSON.generate(model: @model, input: texts.map(&:to_s))
        uri  = URI("#{@base_url}/v1/embeddings")
        response =
          if @http
            @http.post(uri, body, headers)
          else
            Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                read_timeout: @timeout, open_timeout: @timeout) do |http|
              req = Net::HTTP::Post.new(uri.path)
              headers.each { |k, v| req[k] = v }
              req.body = body
              http.request(req)
            end
          end

        code = response.code.to_i
        unless code.between?(200, 299)
          raise UnavailableError, "openai-compatible: HTTP #{code}"
        end

        parsed = JSON.parse(response.body)
        Array(parsed["data"]).map { |d| d["embedding"] }
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
        raise UnavailableError, "openai-compatible: #{e.class}: #{e.message}"
      end

      def dim
        @dim ||= embed(texts: ["."]).first.length
      end

      private

      def headers
        h = {
          "Content-Type" => "application/json",
          "Accept"       => "application/json"
        }
        h["Authorization"] = "Bearer #{@api_key}" if @api_key && !@api_key.to_s.strip.empty?
        h
      end
    end
  end
end
