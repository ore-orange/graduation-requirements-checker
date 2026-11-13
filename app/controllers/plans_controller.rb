# frozen_string_literal: true

# 履修計画表。便覧から科目を検索して予定に追加できる。
class PlansController < ApplicationController
  include StudentWorkspace

  def show
    load_history
    load_plans
    @assessment = assess
    load_term
    load_unavailable_keys
    # いま見ている画面（一覧、または学期の画面）を表す URL の項目。パネルの開け閉めや検索で同じ画面に戻るために使う
    @plan_page_params = @overview ? { view: 'all' } : { term: helpers.term_param(@term) }
    # 便覧カタログは、右側のパネルを開いている（?pane=catalogue）ときだけ検索する。学期の画面でも一覧でも開ける
    @catalogue_open = params[:pane] == 'catalogue'
    load_catalogue if @catalogue_open
    # 追加・削除のフォームに持たせる項目。パネルを開いたまま、検索語も残したまま計画表に戻るために使う
    @catalogue_pane_params = @catalogue_open ? { pane: 'catalogue', q: @query.presence }.compact : {}
  end

  private

  # 表示する学期（1年前期〜4年後期）と、その学期の履修履歴・予定を決める。
  def load_term
    @current_term = current_term
    # view=all のときは全学期の一覧を出す。科目の追加先などに使う @term は今の学期にしておく
    @overview = params[:view] == 'all'
    @term = (parse_term(params[:term]) unless @overview) || @current_term
    @terms = TERMS
    @term_year = term_year(@term)
    @term_open = term_open?(@term)
    @open_terms = TERMS.select { |term| term_open?(term) }
    # 学期のボタンに各学期の単位を出すため、全学期ぶんを学期ごとに分けておく
    @enrollments_by_term = @enrollments.group_by { |enrollment| term_of(enrollment) }
    @plans_by_term = @plans.group_by { |plan| term_of(plan) }
    @term_enrollments = @enrollments_by_term.fetch(@term, [])
    @term_plans = @plans_by_term.fetch(@term, [])
    @unplaced_enrollments = @enrollments.reject { |enrollment| SEMESTERS.include?(enrollment.semester) }
  end

  # もう追加できない科目（修得済み・履修中・予定に追加済み）。学期の画面でも一覧でも使う。
  def load_unavailable_keys
    @unavailable_keys = (@completed + @current).map { |enrollment| enrollment.course.curriculum_key } +
                        @plans.map { |plan| plan.course.curriculum_key }
  end

  # 便覧カタログに出す科目を、検索語（q）で絞り込む。区分がわからない科目を調べるための検索なので、区分では絞り込まない。
  def load_catalogue
    @query = params[:q].to_s.strip
    query = @query.downcase
    @catalogue = @curriculum.fetch('courses').select { |course| matches_query?(course, query) }
    keys = @catalogue.map { |course| course.fetch('key') }
    @persisted_keys = Course.where(curriculum_key: keys).pluck(:curriculum_key)
  end

  def matches_query?(course, query)
    query.blank? || [course['name'], course['number'], course['key']].compact.any? do |value|
      value.downcase.include?(query)
    end
  end
end

