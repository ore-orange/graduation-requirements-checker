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
    user = User.from_google!(uid: auth.uid, email: auth.info.email)
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
end

