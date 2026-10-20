# frozen_string_literal: true

# 進捗ダッシュボードで大項目を開いたときに、その小項目だけを返す。
# 最初の表示に小項目のHTMLを含めないことで、送る量を小さく保つ。
class DashboardGroupsController < ApplicationController
  include StudentWorkspace

  def show
    @definition = StudentWorkspaceHelper::PLANNER_GROUPS.find { |group| group[:id] == params[:id] }
    return head :not_found if @definition.nil?

    load_history
    load_plans
    @assessment = assess
    @metrics = DashboardMetrics.new(assessment: @assessment, enrollments: @enrollments,
                                    plans: @plans, courses_by_key: @courses_by_key)
    render layout: false
  end
end

