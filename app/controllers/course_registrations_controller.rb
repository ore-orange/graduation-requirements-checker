# frozen_string_literal: true

# 「授業登録」タブ。取り込み済みの授業と、確認中のPDFを一覧し、PDFのアップロードを受け付ける。
class CourseRegistrationsController < ApplicationController
  include LocalAccessOnly

  def index
    @uploads = TimetableUpload.includes(:rows).order(:id)
    @paginator = Paginator.new(total: CourseOffering.count, page: params[:page])
    @offerings = CourseOffering.includes(:course).order(:semester, :weekday, :periods, :id)
                               .offset(@paginator.offset).limit(@paginator.per).group_by(&:semester)
  end
end

