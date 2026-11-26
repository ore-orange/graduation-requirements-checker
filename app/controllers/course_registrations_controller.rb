# frozen_string_literal: true

# 「講義登録」タブ。取り込み済みの講義と、確認中のPDFを一覧し、PDFのアップロードを受け付ける。
class CourseRegistrationsController < ApplicationController
  # 取り込みで選べる年度。今年度を中心に前後2年。
  YEAR_RANGE = -2..2

  def index
    @faculties = Faculty.includes(:departments).order(:id)
    @year_options = YEAR_RANGE.map { |offset| current_academic_year + offset }
    @uploads = TimetableUpload.includes(:rows, department: :faculty).order(:id)
    @search = CourseSearch.new(params)
    @paginator = Paginator.new(total: @search.relation.count, page: params[:page])
    @courses = @search.relation.offset(@paginator.offset).limit(@paginator.per)
    # 便覧由来の科目は年度も講義コードも持たないので、これだけで一覧を出すと空の行が並ぶ。
    # 「保存された講義」の有無は、取り込んだ講義(講義コードを持つ行)で判断する。
    @any_course = Course.offered.exists?
    # 絞り込みの年度は、保存済みの講義にある年度だけを出す
    @search_years = Course.distinct.order(year: :desc).pluck(:year).compact
  end

  private

  # 年度は4月から翌年3月まで。3月以前は前の年度として扱う。
  def current_academic_year
    today = Time.zone.today
    today.month < 4 ? today.year - 1 : today.year
  end
end

