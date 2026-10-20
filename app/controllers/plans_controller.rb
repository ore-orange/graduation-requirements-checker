# frozen_string_literal: true

# 履修計画表。便覧から科目を検索して予定に追加できる。
class PlansController < ApplicationController
  include StudentWorkspace

  def show
    load_history
    load_plans
    @assessment = assess
    load_catalogue
  end

  private

  def load_catalogue
    @unavailable_keys = (@completed + @current).map { |enrollment| enrollment.course.curriculum_key } +
                        @plans.map { |plan| plan.course.curriculum_key }
    @query = params[:q].to_s.strip
    @category = params[:category].to_s
    query = @query.downcase
    @catalogue = @curriculum.fetch('courses').select do |course|
      (@category.blank? || course['category'] == @category) && matches_query?(course, query)
    end
    keys = @catalogue.map { |course| course.fetch('key') }
    @persisted_keys = Course.where(curriculum_key: keys).pluck(:curriculum_key)
  end

  def matches_query?(course, query)
    query.blank? || [course['name'], course['number'], course['key']].compact.any? do |value|
      value.downcase.include?(query)
    end
  end
end

