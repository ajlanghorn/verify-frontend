class AboutController < ApplicationController
  layout 'start', except: [:choosing_a_company]

  def index
    FEDERATION_REPORTER.report_registration(federation_info.transaction_simple_id, request)
  end

  def certified_companies
    @identity_providers = IDP_DISPLAY_DATA_CORRELATOR.correlate(federation_info.idps)
  end

  def choosing_a_company
  end

private

  def federation_info
    SESSION_PROXY.federation_info_for_session(cookies)
  end
end
