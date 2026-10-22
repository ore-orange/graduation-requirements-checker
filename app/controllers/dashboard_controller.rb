# frozen_string_literal: true

# 卒業ダッシュボード。区分ごとの充足状況をカードで表示する。
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

