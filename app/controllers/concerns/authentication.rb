# frozen_string_literal: true

# ログインしているかどうかの判定と、セッションの開始・終了。
# 既定では全アクションがログインを要求する。外したいコントローラが
# allow_unauthenticated_access で明示的に申告する。
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**)
      skip_before_action(:require_authentication, **)
    end
  end

  private

  def authenticated?
    resume_session
  end

  def require_authentication
    resume_session || request_authentication
  end

  def resume_session
    Current.session ||= find_session_by_cookie
  end

  def find_session_by_cookie
    Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
  end

  # ログインが終わったら元のページへ戻せるよう、行き先を控えてから送り出す。
  # 控えるのは画面のURLだけにする。POST や DELETE のURLはログイン後に GET されるため、
  # GET を持たないルートだと戻った先が404になる。HEAD も GET と同じルートに流れる。
  def request_authentication
    session[:return_to_after_authenticating] = request.url if request.get? || request.head?
    redirect_to new_session_path
  end

  def after_authentication_url
    session.delete(:return_to_after_authenticating) || root_url
  end

  def start_new_session_for(user)
    user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
      Current.session = session
      cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax }
    end
  end

  def terminate_session
    Current.session.destroy
    cookies.delete(:session_id)
  end
end

