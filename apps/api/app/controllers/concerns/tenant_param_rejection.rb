# frozen_string_literal: true

# Reconaut est tenant unique en v1 (cf. spec `platform` et project.md).
# Toute requete API qui contient un parametre `tenant_id` ou un header
# `X-Tenant` est refusee 400 `tenant_param_unsupported` AVANT toute
# logique metier - on ne veut pas que le futur introduise par accident
# une variabilite par tenant qu'on aurait du mal a retirer.
#
# Source de verite :
#   openspec/changes/add-tech-stack/specs/architecture/spec.md
#     -> Requirement: Single-Tenant Data Model -> Scenario "API rejette
#        tout parametre de tenant"
#   openspec/changes/init-reconaut-platform/tasks.md section 7.1
module TenantParamRejection
  extend ActiveSupport::Concern

  FORBIDDEN_PARAMS  = %w[tenant_id tenant caller_tenant org_id].freeze
  FORBIDDEN_HEADERS = %w[X-Tenant X-Tenant-Id X-Org X-Org-Id].freeze

  included do
    before_action :reject_tenant_params!
  end

  private

  def reject_tenant_params!
    flat = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params
    if flat.is_a?(Hash) && (flat.keys.map(&:to_s) & FORBIDDEN_PARAMS).any?
      return render(status: :bad_request, json: { error: "tenant_param_unsupported" })
    end

    FORBIDDEN_HEADERS.each do |h|
      if request.headers[h].present?
        return render(status: :bad_request, json: { error: "tenant_param_unsupported" })
      end
    end
  end
end
