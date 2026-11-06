# frozen_string_literal: true

# メールアドレスとパスワードでのログイン。
class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[new create]
  rate_limit to: 10, within: 3.minutes, only: :create,
             with: -> { redirect_to new_session_path, alert: '試行が多すぎます。しばらく待ってからやり直してください。' }

  def new; end

  def create
    user = User.authenticate_by(params.permit(:email, :password))
    if user
      start_new_session_for user
      redirect_to after_authentication_url
    else
      # どちらが違うかは伝えない。登録済みのメールアドレスを探られないようにする。
      redirect_to new_session_path, alert: 'メールアドレスまたはパスワードが違います。'
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other, notice: 'ログアウトしました。'
  end
end

