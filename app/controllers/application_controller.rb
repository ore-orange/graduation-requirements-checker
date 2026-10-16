# frozen_string_literal: true

require 'ipaddr'

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :local_demo_access?

  private

  def local_demo_access?
    return false unless DemoAccount.enabled?
    return false unless %w[localhost 127.0.0.1 ::1 [::1]].include?(request.host)
    return true if request.local?
    return false unless ENV['LOCAL_DEMO_PROXY'] == '1'

    remote_address = IPAddr.new(request.get_header('REMOTE_ADDR').to_s)
    remote_address.ipv4? && remote_address.private?
  rescue IPAddr::InvalidAddressError
    false
  end
end

