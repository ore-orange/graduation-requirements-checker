# frozen_string_literal: true

class TimetableUploadsController < ApplicationController
  include LocalAccessOnly

  MAX_PDF_BYTES = 10.megabytes

  before_action :load_upload, only: %i[show destroy commit update_rows page_image]

  # 保存済み・破棄済みの取り込みを開いたときは、エラー画面ではなく一覧に戻す
  rescue_from ActiveRecord::RecordNotFound do
    redirect_to course_registrations_path, alert: 'この取り込みは見つかりません。保存済みか破棄された可能性があります。', status: :see_other
  end

  def show
    @preview = @upload.preview if @upload.all_confirmed?
    @rows = @upload.rows
    @row_errors = flash[:row_errors] || {}
  end

  # PDFと見比べるための、取り込んだPDFのページ画像
  def page_image
    data = @upload.page_image_data(params[:page])
    return head :not_found unless data

    send_data data, type: 'image/png', disposition: 'inline'
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

  # 送られた編集内容とチェックをまとめて保存する。
  # operation=confirm_all のときは、問題のない行をまとめて確認済みにする。
  def update_rows
    result = @upload.apply_edits(submitted_edits, submitted_confirmed_ids,
                                 confirm_valid: params[:operation] == 'confirm_all')
    @upload.add_row_after(params[:after_row_id]) if params[:operation] == 'add_row'
    unless result.failures.empty?
      flash[:row_errors] = result.failures
      flash[:alert] = "確認済みにできない行が#{result.failures.size}行あります。赤い行の内容を直してください。"
    end
    # 同じURLに戻すと、画面全体を読み込み直さず差分だけ反映してスクロール位置を保てる
    redirect_back_or_to timetable_upload_path(@upload), status: :see_other
  end

  def commit
    result = @upload.commit!
    return redirect_to @upload, alert: '未確認の行があるため保存できません。', status: :see_other unless result
    return redirect_to @upload, alert: result.errors.join(' / '), status: :see_other unless result.applied

    redirect_to course_registrations_path, status: :see_other,
                                           notice: "保存しました。講義の新規#{result.created_courses}件、開講情報の新規" \
                                                   "#{result.created_offerings}件・更新#{result.updated_offerings}件。"
  end

  private

  def load_upload
    @upload = TimetableUpload.includes(:rows).find(params.expect(:id))
  end

  # rows[行ID][項目]=値 の形で送られる入力値。許可した項目だけを受け取る。
  def submitted_edits
    raw = params[:rows]
    return {} unless raw.respond_to?(:each_pair)

    raw.each_pair.filter_map do |id, values|
      [id.to_s, values.permit(*TimetableUploadRow::EDITABLE, :course_choice)] if values.respond_to?(:permit)
    end.to_h
  end

  # confirmed[行ID]=1 の形で送られる、チェックされた行
  def submitted_confirmed_ids
    raw = params[:confirmed]
    raw.respond_to?(:keys) ? raw.keys.map(&:to_s) : []
  end

  def upload_error(semester, pdf)
    return '前期か後期を選んでください。' unless TimetableImport::Values::SEMESTERS.include?(semester)
    return 'PDFファイルを選んでください。' unless pdf.respond_to?(:path)
    return "PDFは#{MAX_PDF_BYTES / 1.megabyte}MB以下にしてください。" if pdf.size > MAX_PDF_BYTES

    'PDFファイルを選んでください。' unless File.binread(pdf.path, 5) == '%PDF-'
  end
end

