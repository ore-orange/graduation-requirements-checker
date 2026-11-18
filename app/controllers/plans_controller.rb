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
    load_unavailable_numbers
    # 区分の行の追加の枠も名簿から科目を出すので、パネルを開いていなくても要る。
    @directory = directory
    # いま見ている画面（一覧、または学期の画面）を表す URL の項目。パネルの開け閉めや検索で同じ画面に戻るために使う
    @plan_page_params = @overview ? { view: 'all' } : { term: helpers.term_param(@term) }
    # 便覧カタログは、右側のパネルを開いている（?pane=catalogue）ときだけ検索する。学期の画面でも一覧でも開ける
    @catalogue_open = params[:pane] == 'catalogue'
    load_catalogue if @catalogue_open
    @catalogue_pane_params = catalogue_pane_params
  end

  private

  # 表示する学期（1年前期〜4年後期）と、その学期の履修履歴・予定を決める。
  def load_term
    @current_term = current_term
    # view=all のときは全学期の一覧を出す
    @overview = params[:view] == 'all'
    @term = selected_term
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

  # 学期の画面では、表示する学期（term）。
  # 一覧では、便覧のパネルから追加する先の学期（add_to）。今の学期以降だけ選べて、選んでいなければ今の学期。
  def selected_term
    return parse_term(params[:term]) || @current_term unless @overview

    term = parse_term(params[:add_to])
    term && term_open?(term) ? term : @current_term
  end

  # 追加・削除のフォームや、パネルの中のリンクに持たせる項目。
  # パネルを開いたまま、検索語も、一覧で選んだ追加先の学期も残したまま、計画表に戻るために使う。
  def catalogue_pane_params
    return {} unless @catalogue_open

    add_to = helpers.term_param(@term) if @overview && @term != @current_term
    { pane: 'catalogue', q: @query.presence, add_to: add_to }.compact
  end

  # もう追加できない科目（修得済み・履修中・予定に追加済み）。学期の画面でも一覧でも使う。
  # 計画も履修も Course の行を指すので、科目番号で突き合わせる。
  def load_unavailable_numbers
    @unavailable_numbers = ((@completed + @current).map { |enrollment| enrollment.course.course_number } +
                            @plans.map { |plan| plan.course.course_number }).compact
  end

  # 便覧カタログに出す科目を、検索語（q）で絞り込む。区分がわからない科目を調べるための検索なので、区分では絞り込まない。
  # 名簿(CourseDirectory)が正。便覧に登録の無い科目も、番号から区分が決まるものは名簿に載る。
  def load_catalogue
    @query = params[:q].to_s.strip
    query = @query.downcase
    matched = @directory.categories.flat_map { |category| @directory.in_category(category) }
                        .select { |entry| matches_query?(entry, query) }
    @catalogue_total = matched.size
    @catalogue = matched.first(CATALOGUE_LIMIT)
    @catalogue_limit = CATALOGUE_LIMIT
  end

  def matches_query?(entry, query)
    query.blank? || [entry.name, entry.number].compact.any? { |value| value.downcase.include?(query) }
  end
end

