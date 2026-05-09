# SPDX-License-Identifier: AGPL-3.0-only
class ApplicationController < ActionController::API
  include TenantParamRejection
end
