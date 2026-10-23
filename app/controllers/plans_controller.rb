# frozen_string_literal: true

# 履修計画表。便覧から科目を検索して予定に追加できる。
class PlansController < ApplicationController
  include StudentWorkspace

  SEMESTERS = %w[前期 後期].freeze
  TERMS = (1..4).flat_map { |grade| SEMESTERS.map { |semester| { grade: grade, semester: semester } } }.freeze
  TERM_PARAM = /\A(?<grade>[1-4])-(?<semester>前期|後期)\z/

  def show
    load_history
    load_plans
    @assessment = assess
    load_term
    load_catalogue
  end

  private

  # 表示する学期（1年前期〜4年後期）と、その学期の履修履歴を決める。
  def load_term
    @current_term = current_term
    @term = requested_term || @current_term
    index = TERMS.index(@term)
    @terms = TERMS
    @prev_term = TERMS[index - 1] if index.positive?
    @next_term = TERMS[index + 1]
    @term_year = @student.admission_year + @term[:grade] - 1
    @term_enrollments = @enrollments.select { |enrollment| term_of(enrollment) == @term }
    @unplaced_enrollments = @enrollments.reject { |enrollment| SEMESTERS.include?(enrollment.semester) }
  end

  def requested_term
    match = TERM_PARAM.match(params[:term].to_s)
    { grade: match[:grade].to_i, semester: match[:semester] } if match
  end

  # 年度は4月始まりで、4〜9月を前期、10〜3月を後期とする。在学期間の外なら端の学期にする。
  def current_term(date = Date.current)
    academic_year = date.month >= 4 ? date.year : date.year - 1
    semester_index = date.month.between?(4, 9) ? 0 : 1
    TERMS[(((academic_year - @student.admission_year) * SEMESTERS.size) + semester_index).clamp(0, TERMS.size - 1)]
  end

  # 入学前・5年目以降の履修は1年・4年に寄せる。学期が不明なら nil。
  def term_of(enrollment)
    return unless SEMESTERS.include?(enrollment.semester)

    { grade: (enrollment.academic_year - @student.admission_year + 1).clamp(1, 4), semester: enrollment.semester }
  end

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

