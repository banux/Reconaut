# frozen_string_literal: true

require "json"
require "json-schema"

# Charge et expose les schemas JSON canoniques echanges entre Rails et
# les workers Go via GoodJob.
#
# Source de verite : packages/job-schema/*.json a la racine du monorepo.
# Cf. openspec/changes/add-tech-stack/specs/architecture/spec.md
#   - Requirement: Rails - Go Communication via GoodJob
#   - Scenario: Evolution de schema preservant la compatibilite
#
# Contrat : Validate.call(name, payload) -> [bool, Array<String>].
# Le second element est la liste des erreurs ; vide si OK.
module JobSchema
  class UnknownSchemaError < StandardError; end

  module Registry
    SCHEMAS_PATH = File.expand_path("../../../../../packages/job-schema", __dir__)

    SCHEMAS = {
      "ScanJobV1"    => "scan_job_v1.json",
      "ScanResultV1" => "scan_result_v1.json",
      "HeartbeatV1"  => "heartbeat_v1.json"
    }.freeze

    module_function

    def names
      SCHEMAS.keys
    end

    def load(name)
      filename = SCHEMAS.fetch(name) do
        raise UnknownSchemaError, "Unknown schema: #{name.inspect}"
      end
      path = File.join(SCHEMAS_PATH, filename)
      JSON.parse(File.read(path))
    end

    # Valide un payload contre un schema connu.
    # Retourne [true, []] ou [false, ["erreur 1", "erreur 2"]].
    #
    # On passe explicitement :version => :draft6 pour rester offline-friendly :
    # sans cette option, json-schema essaie de telecharger le meta-schema
    # declare dans $schema, ce qui casse les builds en reseau prive.
    def validate(name, payload)
      schema = load(name).reject { |k, _| k == "$schema" }
      errors = JSON::Validator.fully_validate(
        schema,
        payload,
        errors_as_objects: false,
        version: :draft6
      )
      [errors.empty?, errors]
    end

    # schema_version_for("ScanJobV1") -> 1 (lit `properties.schema_version.const`).
    # Utilisé par la routine doctor pour rapporter la dernière version
    # de schéma connue côté Rails (cf. add-tech-stack section 6 :
    # acceptation `bin/doctor`).
    def schema_version_for(name)
      schema = load(name)
      schema.dig("properties", "schema_version", "const")
    end

    # Map { name => version }, calculée à chaque appel pour rester
    # cohérente avec un éventuel hot-reload des schémas en dev.
    def schema_versions
      names.to_h { |name| [name, schema_version_for(name)] }
    end
  end
end
