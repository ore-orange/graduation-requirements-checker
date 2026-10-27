# frozen_string_literal: true

# 卒業ダッシュボードで区分のカードを開いたときに、その内訳だけを返す。
# 最初の表示に内訳のHTMLを含めないことで、送る量を小さく保つ。
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

