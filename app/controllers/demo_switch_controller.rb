# frozen_string_literal: true

# ナビの切り替えボタン専用。@student は読まないので StudentWorkspace は使わず、
# 他のローカル限定画面と同じ local_demo_access? だけで守る。
class DemoSwitchController < ApplicationController
  before_action :require_local_demo

  def update
    # 年度の妥当性は StudentWorkspace 側(DemoAccount.student_for_year の既定の落とし先)が確かめるので、
    # ここでは不正な値(空文字・数字でない文字列)でも素通しして構わない。
    session[:demo_admission_year] = params[:admission_year].to_i
    redirect_back_or_to root_path
  end

  private

  def require_local_demo
    head :not_found unless local_demo_access?
  end
end

