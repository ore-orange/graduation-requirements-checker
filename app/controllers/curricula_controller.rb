# frozen_string_literal: true

# 便覧PDFを上げて下書き（Curriculum）を作り、どのページを読むかを人が決める画面。
# 一覧とアップロードの入口は /requirements にあり、ここは下書きの確認画面。
# アップロードと同じリクエストの中で、ページ画像とページごとの文字を取り出し、PDFは捨てる。
# 読み取り(AI)は1ページずつ、画面から1リクエストごとに同期で行う。公開は後続のタスクで、ここでは動かさない。
class CurriculaController < ApplicationController
  include LocalAccessOnly

  MAX_PDF_BYTES = 10.megabytes
  FIELD_LABELS = { slug: '識別名(slug)', admission_year: '入学年度', faculty_name: '学部名',
                   department_name: '学科・コース名' }.freeze

  before_action :load_draft, only: %i[show update destroy page_image read_page]

  rescue_from ActiveRecord::RecordNotFound do
    redirect_to requirements_path, alert: 'この下書きは見つかりません。削除された可能性があります。', status: :see_other
  end

  def show; end

  # 取り込み時に作ったページ画像。この下書きの置き場にあるものしか返さない。
  def page_image
    data = @curriculum.page_image_data(params[:page])
    return head :not_found unless data

    send_data data, type: 'image/png', disposition: 'inline'
  end

  # 1ページ読んで、そのページの行だけを返す。読めなかったときも行を返し(失敗の理由はそこに出る)、ステータスで知らせる。
  # 読み取りは外部APIを呼ぶので数秒〜数十秒かかる。バックグラウンドに回さず、画面が1ページずつ順に呼ぶ。
  def read_page
    number = Integer(params[:page].to_s, 10, exception: false)
    return head :not_found unless @curriculum.pages.any? { |page| page['page'] == number }
    return unavailable_reader unless CurriculumReader.available?

    read = CurriculumImport::ReadPage.new(@curriculum, reader: CurriculumReader.new).call(number)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: page_row_stream(number), status: read ? :ok : :unprocessable_content }
      format.html { redirect_to @curriculum, status: :see_other }
    end
  end

  def create
    file = upload_params[:file]
    curriculum = Curriculum.new(upload_params.except(:file))
    curriculum.source_filename = File.basename(file.original_filename) if file.respond_to?(:original_filename)
    error = upload_error(curriculum, file)
    return redirect_to requirements_path, alert: error, status: :see_other if error

    curriculum.pages = []
    curriculum.save!(context: :upload)
    import_material(curriculum, file.path)
    redirect_to curriculum, notice: '下書きを作りました。読むページを選んでください。', status: :see_other
  end

  # pages は読み取り(ReadPage)も、数分かかる要求の最後に書く。読み込んだ手元の pages を書き戻すと、その間に
  # 読み終わったページが未読に戻り、読み直しで要件が二重に入る。行を取り直してロックし、その上で替える。
  def update
    notice = nil
    @curriculum.with_lock do
      notice = params[:page_count].present? ? assign_page_count : assign_page_kinds
      @curriculum.save! unless notice.is_a?(String)
    end
    return redirect_to @curriculum, alert: notice, status: :see_other if notice.is_a?(String)

    redirect_to @curriculum, notice: saved_notice, status: :see_other
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

  # 画像とテキストはPDFがあるいましか取り出せない。取り出せなくても下書きは残し、何が取れなかったかを import_error に書く。
  # ページ数を数えられなければページは空のままで、手で指定できる。
  def import_material(curriculum, pdf_path)
    material = CurriculumImport::PageSource.extract(pdf_path, curriculum.images_dir)
    curriculum.update!(pages: Curriculum.blank_pages(material.page_count, texts: material.texts),
                       import_error: material.errors.join(' ').presence)
  rescue StandardError => e
    Rails.logger.warn("便覧PDFの取り込みに失敗しました: #{e.class}: #{e.message}")
    curriculum.update!(import_error: 'PDFの取り込み中にエラーが起きました。ページ数を指定して始めてください。')
  end

  # APIキーが無いときは読み取りを始めない。画面は読み取りのボタンを出さないので、通るのは古い画面からの操作だけ。
  def unavailable_reader
    respond_to do |format|
      format.turbo_stream { head :service_unavailable }
      format.html { redirect_to @curriculum, alert: '読み取りのAPIキーが設定されていないため、読み取れません。', status: :see_other }
    end
  end

  def page_row_stream(number)
    page = @curriculum.pages.find { |entry| entry['page'] == number }
    locals = { curriculum: @curriculum, page: page, reader_available: true }
    turbo_stream.replace(helpers.dom_id(@curriculum, "page_#{number}"), partial: 'curricula/page_row', locals: locals)
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

    read_before = @curriculum.pages.select { |page| page['status'] == 'read' }.pluck('page')
    @curriculum.assign_page_kinds(kinds)
    @withdrawn_pages = read_before.reject { |number| page_status(number) == 'read' }
    nil
  end

  def page_status(number)
    @curriculum.pages.find { |page| page['page'] == number }['status']
  end

  # 種別を替えたページは読み取りの結果を外して未読に戻す。気づかないまま消えないよう、どのページか知らせる。
  def saved_notice
    return 'ページの指定を保存しました。' if @withdrawn_pages.blank?

    "ページの指定を保存しました。種別を替えた#{@withdrawn_pages.join('・')}ページの読み取り結果は外しました" \
      '(確認済みの科目は残ります)。必要なら読み直してください。'
  end
end

