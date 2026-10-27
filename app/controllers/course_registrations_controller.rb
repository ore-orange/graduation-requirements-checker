# frozen_string_literal: true

# 「講義登録」タブ。取り込み済みの講義と、確認中のPDFを一覧し、PDFのアップロードを受け付ける。
class CourseRegistrationsController < ApplicationController
  include LocalAccessOnly

  # 取り込みで選べる年度。今年度を中心に前後2年。
  YEAR_RANGE = -2..2

  def index
    @faculties = Faculty.includes(:departments).order(:id)
    @year_options = YEAR_RANGE.map { |offset| current_academic_year + offset }
    @uploads = TimetableUpload.includes(:rows, department: :faculty).order(:id)
    @search = CourseOfferingSearch.new(params)
    @paginator = Paginator.new(total: @search.relation.count, page: params[:page])
    @offerings = @search.relation.offset(@paginator.offset).limit(@paginator.per)
    @any_offering = CourseOffering.exists?
    # 絞り込みの年度は、保存済みの講義にある年度だけを出す
    @search_years = CourseOffering.distinct.order(year: :desc).pluck(:year).compact
  end

  private

  # 年度は4月から翌年3月まで。3月以前は前の年度として扱う。
  def current_academic_year
    today = Time.zone.today
    today.month < 4 ? today.year - 1 : today.year
  end
end

