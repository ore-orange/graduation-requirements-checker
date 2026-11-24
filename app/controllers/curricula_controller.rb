# frozen_string_literal: true

# 便覧PDFの要件表の取り込み。PDFとページ範囲から下書きを作り、ページごとに Gemini に読ませて、結果を確かめる。
# 読み取った結果の修正と公開は、まだ無い(このあとの変更で足す)。
# いまはログインしている人なら誰でも使える。管理者の権限は、アプリを公開する前に足す。
class CurriculaController < ApplicationController
  MAX_PDF_BYTES = 10.megabytes

  before_action :load_draft, only: %i[show destroy read_page status page_image]

  rescue_from ActiveRecord::RecordNotFound do
    redirect_to curricula_path, alert: 'この下書きは見つかりません。削除された可能性があります。', status: :see_other
  end

  def index
    @programs = Program.includes(department: :faculty).order(:id)
    @drafts = Curriculum.drafts.order(updated_at: :desc)
  end

  def show
    @program = @draft.program
  end

  def create
    program = Program.find_by(id: params[:program_id])
    error = upload_error(program)
    return redirect_to curricula_path, alert: error, status: :see_other if error

    pdf = params[:pdf]
    draft = CurriculumImport::RequirementsUpload.call(
      pdf_path: pdf.path, filename: File.basename(pdf.original_filename),
      slug: Curriculum.slug_for(program), admission_year: admission_year, page_range: params[:page_range]
    )
    redirect_to draft, notice: '下書きを作りました。ページごとに「読み取る」を押してください。', status: :see_other
  rescue CurriculumImport::RequirementsUpload::Error => e
    redirect_to curricula_path, alert: e.message, status: :see_other
  end

  def destroy
    @draft.destroy!
    redirect_to curricula_path, notice: '下書きを削除しました。', status: :see_other
  end

  # 1ページの読み取りを始める。Gemini の応答には数十秒〜数分かかるので、ここでは「読み取り中」にしてジョブに渡し、
  # すぐ画面に戻す。結果は画面が status を問い合わせて受け取る。
  def read_page
    page = Integer(params[:page], 10, exception: false)
    return redirect_to @draft, alert: 'このページは下書きにありません。', status: :see_other unless @draft.page_entry(page)
    return redirect_to @draft, alert: '読み取りのAPIキーが設定されていません。', status: :see_other unless GeminiClient.available?

    if @draft.start_reading!(page)
      ReadRequirementsPageJob.perform_later(@draft.id, page)
      notice = "#{page}ページの読み取りを始めました。終わると、この画面に結果が出ます。"
    else
      notice = "#{page}ページは読み取り中です。"
    end
    redirect_to curriculum_path(@draft, anchor: "page-#{page}"), notice: notice, status: :see_other
  end

  # ページごとの読み取りの状態。reading が false になったら、画面は読み込み直して結果を出す。
  def status
    render json: { reading: @draft.reading?,
                   pages: @draft.pages.map { |entry| { page: entry['page'], status: @draft.page_status(entry) } } }
  end

  def page_image
    data = @draft.page_image_data(params[:page])
    return head :not_found unless data

    send_data data, type: 'image/png', disposition: 'inline'
  end

  private

  # 公開済みの便覧は、ここでは開かない(下書きだけを扱う)。
  def load_draft
    @draft = Curriculum.drafts.find(params.expect(:id))
  end

  def admission_year
    year = Integer(params[:admission_year].to_s, 10, exception: false)
    year if Curriculum.admission_year_range.cover?(year)
  end

  def upload_error(program)
    pdf = params[:pdf]
    return '学部・学科・コースを選んでください。' unless program
    return '入学年度を選んでください。' unless admission_year
    return 'PDFファイルを選んでください。' unless pdf.respond_to?(:path)
    return "PDFは#{MAX_PDF_BYTES / 1.megabyte}MB以下にしてください。" if pdf.size > MAX_PDF_BYTES

    'PDFファイルを選んでください。' unless File.binread(pdf.path, 5) == '%PDF-'
  end
end

