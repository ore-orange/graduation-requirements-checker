# frozen_string_literal: true

# 履修計画表。便覧から科目を検索して予定に追加できる。
class PlansController < ApplicationController
  include StudentWorkspace

  # 検索・一覧は、画面に描ける数で打ち切る。courses テーブルは時間割を取り込むほど増え、ページ送りが無いため。
  CATALOGUE_LIMIT = 200

  def show
    load_history
    load_plans
    @assessment = assess
    load_term
    load_catalogue
  end

  private

  # 表示する学期（1年前期〜4年後期）と、その学期の履修履歴・予定を決める。
  def load_term
    @current_term = current_term
    @term = parse_term(params[:term]) || @current_term
    index = TERMS.index(@term)
    @terms = TERMS
    @prev_term = TERMS[index - 1] if index.positive?
    @next_term = TERMS[index + 1]
    @term_year = term_year(@term)
    @term_open = term_open?(@term)
    @term_enrollments = @enrollments.select { |enrollment| term_of(enrollment) == @term }
    @term_plans = @plans.select { |plan| term_of(plan) == @term }
    @unplaced_enrollments = @enrollments.reject { |enrollment| SEMESTERS.include?(enrollment.semester) }
  end

  def load_catalogue
    @directory = directory
    @unavailable_numbers = ((@completed + @current).map { |enrollment| enrollment.course.course_number } +
                            @plans.map { |plan| plan.course.course_number }).compact
    @query = params[:q].to_s.strip
    @category = params[:category].to_s
    query = @query.downcase
    categories = @category.blank? ? @directory.categories : [@category]
    matched = categories.flat_map { |category| @directory.in_category(category) }
                        .select { |entry| matches_query?(entry, query) }
    @catalogue_total = matched.size
    @catalogue = matched.first(CATALOGUE_LIMIT)
    @catalogue_limit = CATALOGUE_LIMIT
  end

  def matches_query?(entry, query)
    query.blank? || [entry.name, entry.number].compact.any? { |value| value.downcase.include?(query) }
  end
end

