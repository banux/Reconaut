class ApplicationController < ActionController::API
  include TenantParamRejection
end
