# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Healthcheck non authentifié : `GET /healthz` -> 200 + {"status":"ok"}.
# Cible : load-balancer / k8s probes / prometheus blackbox.
#
# Cf. openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md
# (Requirement: REST API Reduced to Bootstrap, Health and MCP Transport).
#
# Aucune ligne d'audit n'est écrite : le bruit serait disproportionné pour
# un endpoint de probe appelé toutes les secondes par les LB.
class HealthController < ActionController::API
  def show
    render status: :ok, json: { status: "ok" }
  end
end
