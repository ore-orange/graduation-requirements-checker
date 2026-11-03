# frozen_string_literal: true

# ナビの切り替えボタン専用。@student は読まないので StudentWorkspace は使わず、
# 他のマスタ系のローカル限定画面(講義登録など)と同じ LocalAccessOnly だけで守る。
class DemoSwitchController < ApplicationController
  include LocalAccessOnly

  def update
    # 年度の妥当性は StudentWorkspace 側(DemoAccount.student_for_year やその既定の落とし先)が確かめるので、
    # ここでは不正な値(空文字・数字でない文字列・配列やハッシュ)でも例外にせず素通しして構わない。
    session[:demo_admission_year] = Integer(params[:admission_year].to_s, exception: false) || 0
    redirect_back_or_to root_path
  end
end

