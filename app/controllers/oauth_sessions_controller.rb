# frozen_string_literal: true

# Googleアカウントでのログイン。
class OauthSessionsController < ApplicationController
  allow_unauthenticated_access

  # OmniAuthのミドルウェアがPOSTを先に受け取ってGoogleへ飛ばすため、通常ここには来ない。
  # ミドルウェアが外れている場合に存在しないふりをする。
  def passthru
    head :not_found
  end

  def create
    identity = GoogleIdentity.from(auth)
    return redirect_to new_session_path, alert: denied_message unless identity.allowed_domain?

    user = User.from_google!(uid: identity.uid, email: identity.email)
    start_new_session_for user
    redirect_to after_authentication_url
  end

  def failure
    redirect_to new_session_path, alert: 'Googleでのログインに失敗しました。'
  end

  private

  def auth
    request.env.fetch('omniauth.auth')
  end

  # どのドメインなら通るかは伏せない。学内の利用者が私用のアカウントで
  # 入ろうとして断られたとき、何をすればよいか分からなくなるため。
  def denied_message
    "#{GoogleIdentity.allowed_domains.join('、')} のGoogleアカウントでログインしてください。"
  end
end

