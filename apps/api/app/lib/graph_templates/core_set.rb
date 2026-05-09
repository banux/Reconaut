# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require_relative "registry"

# Set noyau (≤ 10) de templates Cypher exposes a l'agent.
#
# Source de verite : openspec/changes/add-graph-retrieval/tasks.md section 3.2.
# Chaque template est en lecture seule, parametre, et borne (depth ≤ 3,
# limit ≤ 100). La numerotation des templates suit la liste de la spec.
#
# Aucune logique d'execution ici : la couche d'execution Cypher (sur AGE)
# viendra dans une iteration suivante. Ce fichier ne fait que materialiser
# le catalogue ; le registry valide la conformite read-only a l'enregistrement.
module GraphTemplates
  module CoreSet
    GRAPH_NAME = "reconaut"

    module_function

    def register_all!(registry: Registry)
      registry.reset!

      # 1. cert_cluster : hotes partageant un certificat TLS feuille.
      registry.register(
        id: "cert_cluster",
        params: {
          cert_sha256: { type: :string, min_length: 64, max_length: 64 },
          limit:       { type: :integer, required: false, default: 100 }
        },
        cypher: <<~CYPHER
          MATCH (c:Certificate {sha256: $cert_sha256})<-[:PRESENTS]-(h:Host)
          RETURN h.id AS host_id, h.scanned_at AS scanned_at
          LIMIT $limit
        CYPHER
      )

      # 2. host_neighborhood : voisinage AS / range / cert d'un hote.
      registry.register(
        id: "host_neighborhood",
        params: {
          host_id: { type: :string, min_length: 1, max_length: 64 },
          depth:   { type: :integer }
        },
        cypher: <<~CYPHER
          MATCH (h:Host {id: $host_id})
          OPTIONAL MATCH path = (h)-[:IN_AS|IN_RANGE|PRESENTS|EXPOSES*1..3]-(n)
          RETURN nodes(path) AS nodes, relationships(path) AS edges
          LIMIT 100
        CYPHER
      )

      # 3. assets_by_kind : actifs paginatables par label.
      registry.register(
        id: "assets_by_kind",
        params: {
          kind:  { type: :enum, values: %w[Host Service Domain Certificate AutonomousSystem IPRange] },
          limit: { type: :integer, required: false, default: 50 }
        },
        cypher: <<~CYPHER
          MATCH (n)
          WHERE labels(n)[0] = $kind
          RETURN n
          LIMIT $limit
        CYPHER
      )

      # 4. service_with_vulnerability : services hebergeant une CVE precise.
      registry.register(
        id: "service_with_vulnerability",
        params: {
          cve_id: { type: :string, min_length: 5, max_length: 32 },
          limit:  { type: :integer, required: false, default: 100 }
        },
        cypher: <<~CYPHER
          MATCH (v:Vulnerability {cve_id: $cve_id})<-[:AFFECTED_BY]-(c:CPE)<-[:MATCHES_CPE]-(s:Service)<-[:EXPOSES]-(h:Host)
          RETURN h.id AS host_id, s.port AS port, s.proto AS proto, h.scanned_at AS scanned_at
          LIMIT $limit
        CYPHER
      )

      # 5. as_hosts : hotes dans un AS, filtrable par pays.
      registry.register(
        id: "as_hosts",
        params: {
          as_number: { type: :integer },
          country:   { type: :string, required: false, max_length: 2, default: nil },
          limit:     { type: :integer, required: false, default: 100 }
        },
        cypher: <<~CYPHER
          MATCH (h:Host)-[:IN_AS]->(a:AutonomousSystem {number: $as_number})
          WHERE $country IS NULL OR h.country = $country
          RETURN h.id AS host_id, h.country AS country, h.scanned_at AS scanned_at
          LIMIT $limit
        CYPHER
      )

      # 6. domain_chain : chaine Domain -> Host pour un domaine.
      registry.register(
        id: "domain_chain",
        params: {
          domain: { type: :string, min_length: 1, max_length: 255 },
          limit:  { type: :integer, required: false, default: 100 }
        },
        cypher: <<~CYPHER
          MATCH (d:Domain {name: $domain})-[:RESOLVES_TO]->(h:Host)
          RETURN d.name AS domain, h.id AS host_id, h.scanned_at AS scanned_at
          LIMIT $limit
        CYPHER
      )

      # 7. path_between : plus court chemin entre deux noeuds (max 3).
      registry.register(
        id: "path_between",
        params: {
          from_node_id: { type: :string, min_length: 1, max_length: 64 },
          to_node_id:   { type: :string, min_length: 1, max_length: 64 },
          depth:        { type: :integer }
        },
        cypher: <<~CYPHER
          MATCH (a {id: $from_node_id}), (b {id: $to_node_id})
          MATCH path = shortestPath((a)-[*..3]-(b))
          RETURN nodes(path) AS nodes, relationships(path) AS edges
          LIMIT 1
        CYPHER
      )

      # 8. host_certificates : certificats presentes par un hote, avec partages.
      registry.register(
        id: "host_certificates",
        params: {
          host_id: { type: :string, min_length: 1, max_length: 64 }
        },
        cypher: <<~CYPHER
          MATCH (h:Host {id: $host_id})-[:PRESENTS]->(c:Certificate)
          OPTIONAL MATCH (c)<-[:PRESENTS]-(other:Host)
          WHERE other.id <> $host_id
          RETURN c.sha256 AS cert_sha256, collect(other.id) AS shared_with
          LIMIT 100
        CYPHER
      )

      # 9. cve_exposed_count : comptage agrege par CVE.
      registry.register(
        id: "cve_exposed_count",
        params: {
          cve_id: { type: :string, min_length: 5, max_length: 32 }
        },
        cypher: <<~CYPHER
          MATCH (v:Vulnerability {cve_id: $cve_id})<-[:AFFECTED_BY]-(c:CPE)<-[:MATCHES_CPE]-(s:Service)<-[:EXPOSES]-(h:Host)
          RETURN count(DISTINCT h) AS exposed_hosts, count(DISTINCT s) AS exposed_services
        CYPHER
      )

      # 10. subsidiaries_assets : actifs des filiales declarees d'une organisation.
      registry.register(
        id: "subsidiaries_assets",
        params: {
          parent_org_id: { type: :string, min_length: 1, max_length: 64 },
          limit:         { type: :integer, required: false, default: 100 }
        },
        cypher: <<~CYPHER
          MATCH (p:Organization {id: $parent_org_id})-[:OWNS|PARENT_OF*1..3]->(child:Organization)
          MATCH (child)-[:OWNS]->(asset)
          WHERE asset:Domain OR asset:Host
          RETURN child.id AS subsidiary_id, asset.id AS asset_id, labels(asset)[0] AS asset_kind
          LIMIT $limit
        CYPHER
      )

      registry
    end
  end
end
