# frozen_string_literal: true

# 進捗ダッシュボード。大項目ごとの充足状況を1枚のカードにまとめて表示する。
class DashboardController < ApplicationController
  include StudentWorkspace

  def show
    load_history
    load_plans
    @assessment = assess
    @metrics = DashboardMetrics.new(assessment: @assessment, enrollments: @enrollments,
                                    plans: @plans, courses_by_key: @courses_by_key)
  end
end

