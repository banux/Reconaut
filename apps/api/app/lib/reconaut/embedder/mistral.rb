# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "json"
require "net/http"
require "uri"

module Reconaut
  module Embedder
    # Mistral : POST https://api.mistral.ai/v1/embeddings
    # { model, input: [...] } -> { data: [{ embedding: [...] }, ...] }
    class Mistral
      DEFAULT_BASE_URL = "https://api.mistral.ai"
      DEFAULT_TIMEOUT  = 2.5

      def initialize(api_key:, model: "mistral-embed", base_url: DEFAULT_BASE_URL,
                     http_client: nil, timeout: DEFAULT_TIMEOUT)
        raise ArgumentError, "api_key required" if api_key.to_s.strip.empty?

        @api_key = api_key
        @model   = model
        @base    = base_url.chomp("/")
        @http    = http_client
        @timeout = timeout
      end

      attr_reader :model

      def provider = "mistral"

      def embed(texts:)
        return [] if texts.empty?

        body = JSON.generate(model: @model, input: texts.map(&:to_s))
        uri  = URI("#{@base}/v1/embeddings")
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
          raise UnavailableError, "mistral: HTTP #{code}"
        end

        parsed = JSON.parse(response.body)
        Array(parsed["data"]).map { |d| d["embedding"] }
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
        raise UnavailableError, "mistral: #{e.class}: #{e.message}"
      end

      def dim
        @dim ||= embed(texts: ["."]).first.length
      end

      private

      def headers
        {
          "Content-Type"  => "application/json",
          "Accept"        => "application/json",
          "Authorization" => "Bearer #{@api_key}"
        }
      end
    end
  end
end
