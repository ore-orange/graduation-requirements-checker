# frozen_string_literal: true

class TimetableUploadsController < ApplicationController
  include LocalAccessOnly

  MAX_PDF_BYTES = 10.megabytes

  before_action :load_upload, only: %i[show destroy commit confirm_all]

  # 保存済み・破棄済みの取り込みを開いたときは、エラー画面ではなく一覧に戻す
  rescue_from ActiveRecord::RecordNotFound do
    redirect_to course_registrations_path, alert: 'この取り込みは見つかりません。保存済みか破棄された可能性があります。', status: :see_other
  end

  def show
    @preview = @upload.preview if @upload.all_confirmed?
    @paginator = Paginator.new(total: @upload.rows.size, page: params[:page])
    @page_rows = @upload.rows.slice(@paginator.offset, @paginator.per)
  end

  def create
    semester = params[:semester].to_s
    pdf = params[:pdf]
    error = upload_error(semester, pdf)
    return redirect_to course_registrations_path, alert: error, status: :see_other if error

    upload = TimetableUpload.build_from_pdf(pdf.path, semester: semester,
                                                      filename: File.basename(pdf.original_filename))
    redirect_to upload, notice: 'PDFを読み取りました。内容をPDFと見比べて、行ごとに確認してください。', status: :see_other
  rescue TimetableImport::PdfParser::Error => e
    redirect_to course_registrations_path, alert: e.message, status: :see_other
  end

  def destroy
    @upload.destroy!
    redirect_to course_registrations_path, notice: '取り込みを破棄しました。', status: :see_other
  end

  # 問題のない行(読み取りで要確認が付かず、値も正しい行)をまとめて確認済みにする
  def confirm_all
    targets = @upload.rows.select { |row| !row.confirmed && row.review_reason.blank? && row.problems.empty? }
    targets.each { |row| row.update!(confirmed: true) }
    redirect_to timetable_upload_path(@upload, page: params[:page].presence),
                notice: "#{targets.size}行を確認済みにしました（全ページ対象）。要確認の行は個別に確認してください。", status: :see_other
  end

  def commit
    result = @upload.commit!
    return redirect_to @upload, alert: '未確認の行があるため保存できません。', status: :see_other unless result
    return redirect_to @upload, alert: result.errors.join(' / '), status: :see_other unless result.applied

    redirect_to course_registrations_path, status: :see_other,
                                           notice: "保存しました。科目の新規#{result.created_courses}件、開講情報の新規" \
                                                   "#{result.created_offerings}件・更新#{result.updated_offerings}件。"
  end

  private

  def load_upload
    @upload = TimetableUpload.includes(:rows).find(params.expect(:id))
  end

  def upload_error(semester, pdf)
    return '前期か後期を選んでください。' unless TimetableImport::Values::SEMESTERS.include?(semester)
    return 'PDFファイルを選んでください。' unless pdf.respond_to?(:path)
    return "PDFは#{MAX_PDF_BYTES / 1.megabyte}MB以下にしてください。" if pdf.size > MAX_PDF_BYTES

    'PDFファイルを選んでください。' unless File.binread(pdf.path, 5) == '%PDF-'
  end
end

