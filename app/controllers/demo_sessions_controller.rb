# frozen_string_literal: true

# 認証が入る前から公開しているデモ画面への入口。
# 固定のデモ学生としてログインするだけで、ログイン後の扱いは通常のユーザーと変わらない。
class DemoSessionsController < ApplicationController
  allow_unauthenticated_access
  before_action :require_demo_access

  def create
    start_new_session_for DemoData.load!.user
    redirect_to root_path
  end

  private

  def require_demo_access
    head :not_found unless local_demo_access?
  end
end

