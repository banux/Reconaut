# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "rack/utils"

# Mcp::ExportsController#download : sert un export généré par le tool
# MCP `export_report`. Vérifie le token HMAC-SHA256 au temps constant,
# streame le fichier, puis le supprime (one-shot).
#
# Cf. openspec/changes/add-mcp-engine/specs/mcp-server/spec.md
#   -> Requirement: MCP Tool `export_report` (download endpoint)
#
# Erreurs renvoyées en `404 Not Found` (jamais 401) pour ne pas
# confirmer l'existence d'un fichier à un attaquant qui devine.
module Mcp
  class ExportsController < ApplicationController
    include McpTlsPosture

    def download
      uuid       = params[:id].to_s
      token      = params[:token].to_s
      expires_at = params[:expires_at].to_s

      return render_404 if uuid.empty? || token.empty? || expires_at.empty?
      return render_404 unless valid_uuid?(uuid)
      return render_404 unless token_valid?(uuid, expires_at, token)
      return render_404 if expired?(expires_at)

      path, content_type = locate_file(uuid)
      return render_404 if path.nil?

      data = File.read(path)
      File.unlink(path) # one-shot
      send_data data, type: content_type, disposition: "attachment", filename: File.basename(path)
    end

    private

    def render_404
      render status: :not_found, json: { error: "not_found" }
    end

    def valid_uuid?(uuid)
      uuid =~ /\A[0-9a-f-]{36}\z/i
    end

    def token_valid?(uuid, expires_at, provided)
      expected = ::Mcp::CoreTools.export_token_for(uuid, expires_at)
      ::Rack::Utils.secure_compare(expected, provided)
    end

    def expired?(expires_at_iso)
      Time.iso8601(expires_at_iso) < Time.now
    rescue ArgumentError
      true
    end

    def locate_file(uuid)
      dir = ::Mcp::CoreTools.export_dir
      json_path = File.join(dir, "#{uuid}.json")
      csv_path  = File.join(dir, "#{uuid}.csv")

      if File.exist?(json_path)
        # Le format STIX2 partage l'extension .json — on lit la
        # première ligne pour distinguer (heuristique : un bundle STIX
        # commence par `{` et contient `"type": "bundle"` proche du
        # début). Plus robuste : associer le content_type au moment
        # de l'export et le persister à côté. Cohérent avec le
        # principe one-shot : on tolère un Content-Type generique
        # `application/json` pour les deux variants — un consommateur
        # qui a demandé stix2 le sait.
        content_type = sniff_content_type(json_path)
        return [json_path, content_type]
      elsif File.exist?(csv_path)
        return [csv_path, "text/csv"]
      end

      [nil, nil]
    end

    def sniff_content_type(path)
      head = File.read(path, 200, mode: "r")
      if head.include?('"type": "bundle"') || head.include?('"type":"bundle"')
        "application/stix+json;version=2.1"
      else
        "application/json"
      end
    rescue StandardError
      "application/json"
    end
  end
end
