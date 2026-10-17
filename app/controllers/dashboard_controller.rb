# frozen_string_literal: true

# 進捗ダッシュボード。実績判定と見込み判定をまとめて表示する。
class DashboardController < ApplicationController
  include StudentWorkspace

  def show
    load_history
    load_plans
    @assessment = assess
  end
end

