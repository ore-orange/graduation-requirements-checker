# frozen_string_literal: true

require 'open3'

# 便覧PDFを上げて下書き（Curriculum）を作り、どのページを読むかを人が決める画面。
# 一覧とアップロードの入口は /requirements にあり、ここは下書きの確認画面。
# 画像化・文字の取り出し・AI・公開は後続のタスクで、ここでは動かさない。
class CurriculaController < ApplicationController
  include LocalAccessOnly

  MAX_PDF_BYTES = 10.megabytes
  FIELD_LABELS = { slug: '識別名(slug)', admission_year: '入学年度', faculty_name: '学部名',
                   department_name: '学科・コース名' }.freeze

  class PageCountError < StandardError; end

  before_action :load_draft, only: %i[show update destroy]

  rescue_from ActiveRecord::RecordNotFound do
    redirect_to requirements_path, alert: 'この下書きは見つかりません。削除された可能性があります。', status: :see_other
  end

  # PDFのページ数を Ghostscript で数える。後続のタスクで、画像化・文字の取り出しとともに PageSource へ移す。
  # 数えられなければ PageCountError。PDFそのものはここでは保存せず、アップロードされた一時ファイルも使い終わったら消える。
  def self.count_pages(path)
    out, err, status = Open3.capture3('gs', '-q', '-dNODISPLAY', '-dNOPAUSE', '-dBATCH', '-dSAFER',
                                      "--permit-file-read=#{path}", "-sInput=#{path}",
                                      '-c', 'Input (r) file runpdfbegin pdfpagecount = quit')
    count = Integer(out.to_s.strip, 10, exception: false)
    unless status.success? && count&.positive?
      Rails.logger.warn("ページ数を数えられませんでした: #{err.to_s.lines.first(3).join.strip}")
      raise PageCountError, 'PDFのページ数を数えられませんでした。壊れたPDFか確認してください。'
    end
    raise PageCountError, "ページ数が多すぎます（#{count}ページ）。" if count > Curriculum::MAX_PAGES

    count
  rescue Errno::ENOENT
    raise PageCountError, 'Ghostscript(gs)が見つかりません。'
  end

  def show; end

  def create
    file = upload_params[:file]
    curriculum = Curriculum.new(upload_params.except(:file))
    curriculum.source_filename = File.basename(file.original_filename) if file.respond_to?(:original_filename)
    error = upload_error(curriculum, file)
    return redirect_to requirements_path, alert: error, status: :see_other if error

    # ページ数を数えられなくても下書きは作る。ページは手で指定できる。
    begin
      curriculum.pages = Curriculum.blank_pages(self.class.count_pages(file.path))
    rescue PageCountError => e
      curriculum.pages = []
      curriculum.import_error = e.message
    end
    curriculum.save!(context: :upload)
    redirect_to curriculum, notice: '下書きを作りました。読むページを選んでください。', status: :see_other
  end

  def update
    notice = params[:page_count].present? ? assign_page_count : assign_page_kinds
    return redirect_to @curriculum, alert: notice, status: :see_other if notice.is_a?(String)

    @curriculum.save!
    redirect_to @curriculum, notice: 'ページの指定を保存しました。', status: :see_other
  end

  # 下書きは作業中の文書なので、そのまま消す。公開済みは load_draft で弾く。
  def destroy
    @curriculum.destroy!
    redirect_to requirements_path, notice: '下書きを削除しました。', status: :see_other
  end

  private

  def upload_params
    @upload_params ||= begin
      raw = params[:curriculum]
      # ?curriculum=x のように、ハッシュでない値が来ても落とさず、空の入力として扱う
      raw = ActionController::Parameters.new unless raw.is_a?(ActionController::Parameters)
      raw.permit(:slug, :admission_year, :faculty_name, :department_name, :file)
    end
  end

  # 公開済みの便覧は学生の判定に使われているので、この画面では開かず、直さず、消さない。
  def load_draft
    @curriculum = Curriculum.find(params.expect(:id))
    return unless @curriculum.published?

    redirect_to requirements_path, alert: '公開済みの便覧は、この画面からは開けません。', status: :see_other
  end

  def upload_error(curriculum, file)
    unless curriculum.valid?(:upload)
      labels = curriculum.errors.attribute_names.filter_map { |name| FIELD_LABELS[name] }
      hint = curriculum.errors.include?(:slug) ? '識別名は半角英小文字で始め、半角英小文字・数字・_だけにしてください。' : ''
      return "#{labels.join('・')}を正しく入力してください。#{hint}"
    end
    return 'PDFファイルを選んでください。' unless file.respond_to?(:path)
    return "PDFは#{MAX_PDF_BYTES / 1.megabyte}MB以下にしてください。" if file.size > MAX_PDF_BYTES

    'PDFファイルを選んでください。' unless File.binread(file.path, 5) == '%PDF-'
  end

  # ページが無い下書きに、ページ数を手で指定する。エラーのときは文言を返す。
  def assign_page_count
    count = Integer(params[:page_count].to_s, 10, exception: false)
    unless @curriculum.pages.empty? && count&.between?(1, Curriculum::MAX_PAGES)
      return "ページ数は1〜#{Curriculum::MAX_PAGES}で指定してください。すでにページがある下書きは変えられません。"
    end

    @curriculum.pages = Curriculum.blank_pages(count)
    @curriculum.import_error = nil
  end

  # ページごとの種別を替える。エラーのときは文言を返す。
  def assign_page_kinds
    raw = params[:pages]
    kinds = raw.respond_to?(:each_pair) ? raw.each_pair.to_h { |page, kind| [page.to_s, kind.to_s] } : {}
    return '科目表・要件表・読まない のいずれかを、存在するページに指定してください。' unless kinds.any? && @curriculum.page_kinds_assignable?(kinds)

    @curriculum.assign_page_kinds(kinds)
    nil
  end
end

