# frozen_string_literal: true

# 便覧PDFを上げて下書き（Curriculum）を作り、どのページを読むかを人が決める画面。
# 一覧とアップロードの入口は /requirements にあり、ここは下書きの確認画面。
# アップロードと同じリクエストの中で、ページ画像とページごとの文字を取り出し、PDFは捨てる。
# 読み取り(AI)は1ページずつ、画面から1リクエストごとに同期で行う。
class CurriculaController < ApplicationController
  include CurriculumUploadParams
  include CurriculaPagesUpdate

  MAX_PDF_BYTES = 10.megabytes
  # 識別名(slug)は入力させない(Curriculum が学部名・学科コース名から決める)ので、ここに欄の名前は無い。
  FIELD_LABELS = { admission_year: '入学年度', faculty_name: '学部名', department_name: '学科・コース名' }.freeze

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
    curriculum = Curriculum.new(curriculum_attributes)
    curriculum.source_filename = File.basename(file.original_filename) if file.respond_to?(:original_filename)
    error = upload_error(curriculum, file)
    # 保存はしていないが、送られた入学年度・学部・学科コースは curriculum が持っている。操作した人が選んだ組み合わせの画面に戻して
    # 理由を出す(選択なしの画面に戻すと、選び直しになり、取り込みの入口も畳まれた「新しく作る」側に隠れる)。名前や年度が空なら素のパス。
    return redirect_to requirements_location(curriculum), alert: error, status: :see_other if error

    curriculum.pages = []
    curriculum.save_upload!
    import_material(curriculum, file.path)
    redirect_to curriculum, notice: '下書きを作りました。読むページを選んでください。', status: :see_other
  end

  # ページの指定の保存。画面の「この指定で読み取る」は fetch で Turbo Stream を受け、そのまま読み取りに入る(警告は応答に載せる)。
  # JavaScript が動かないときの「ページの指定を保存」は html で、いまどおり画面を開き直す。
  #
  # pages は読み取り(ReadPage)も、数分かかる要求の最後に書く。読み込んだ手元の pages を書き戻すと、その間に
  # 読み終わったページが未読に戻り、読み直しで要件が二重に入る。行を取り直してロックし、その上で替える。
  #
  # load_draft は下書きのときだけ通すが、ロックが明くまでの間に別の操作がこの便覧を公開していることがある
  # (公開も with_lock で行をロックするので、ロックの順番で先に公開が済んでいれば、ここが見るのは公開済みの行)。
  # ロックの中でもう一度確かめ、公開済みなら何もせず断る。
  def update
    notice = nil
    @curriculum.with_lock do
      next notice = published_alert if @curriculum.published?

      notice = params[:page_count].present? ? assign_page_count : assign_page_kinds
      @curriculum.save! unless notice.is_a?(String)
    end
    respond_to do |format|
      format.html { redirect_after_update(notice) }
      format.turbo_stream { render_update_stream(notice) }
    end
  end

  # 下書きは作業中の文書なので、そのまま消す。公開済みは load_draft で弾く。それでも、消す直前にロックが明くまでの
  # 間に公開が済んでいることがあるので、行をロックしてもう一度確かめてから消す(公開済みの行を消させない)。
  def destroy
    published = false
    destroyed = false
    @curriculum.with_lock do
      published = @curriculum.published?
      destroyed = @curriculum.destroy unless published
    end
    return redirect_to requirements_location, alert: published_alert, status: :see_other if published
    return redirect_to requirements_location, alert: destroy_refusal, status: :see_other unless destroyed

    redirect_to requirements_location, notice: '下書きを削除しました。', status: :see_other
  end

  private

  # 操作した便覧の、卒業要件の確認画面。選択を引き継いで、操作の結果をそのまま見せる(選択なしの画面に戻すと、
  # 自分の操作のあとに空の画面へ落ちる)。学部名・学科コース名を持たない古い行は選択できないので、選択なしの画面にする。
  # 公開・削除のあとでも属性はメモリに残っているので、削除した行からも作れる。保存前の行(取り込みの入力が不正だったとき)も同じ。
  def requirements_location(curriculum = @curriculum)
    selection = CurriculumSelection.for(curriculum, choices: choices)
    selection.named? ? requirements_path(selection.to_params) : requirements_path
  end

  def destroy_refusal
    @curriculum.errors.full_messages.to_sentence.presence || '削除できませんでした。'
  end

  # 公開済みになったあとの操作を断るときの文言。load_draft がここへ来させないための関門だが、
  # ロックが明くまでの間に別の操作が先に公開していることがあるので、行をロックする操作はもう一度ここで確かめる。
  def published_alert = '公開済みの便覧は、この画面からは開けません。'

  # 公開済みの便覧は学生の判定に使われているので、この画面では開かず、直さず、消さない。直すときは「複製して直す」。
  def load_draft
    @curriculum = Curriculum.find(params.expect(:id))
    return unless @curriculum.published?

    redirect_to requirements_location, alert: published_alert, status: :see_other
  end

  # department_name にコースを結ばず送れてしまう経路(JSが効かない・迂回された送信)への備え。学科名だけの
  # department_name は、コースのある学科(例: 工学科)では別の課程を指してしまうので、画面の required だけに頼らない。
  def upload_error(curriculum, file)
    return 'コースを選んでください。' if course_missing?

    unless curriculum.valid?(:upload)
      labels = curriculum.errors.attribute_names.filter_map { |name| FIELD_LABELS[name] }
      return "#{labels.join('・')}を正しく入力してください。"
    end
    return 'PDFファイルを選んでください。' unless file.respond_to?(:path)
    return "PDFは#{MAX_PDF_BYTES / 1.megabyte}MB以下にしてください。" if file.size > MAX_PDF_BYTES

    'PDFファイルを選んでください。' unless File.binread(file.path, 5) == '%PDF-'
  end

  # 選んだ学科にコースがあるのに、コースを選んでいない(または「その他」を選んだのに打っていない)か。
  # 「その他」で新しい学部・学科を登録するときは、既存のコースに縛られないので見ない。
  def course_missing?
    department = chosen_name(:department_name)
    return false if department.blank?

    choices.courses_for(department).any? && chosen_name(:course_name).blank?
  end

  # プルダウンの選択肢。1リクエストの中で何度も引くので、1つを使い回す。
  def choices = @choices ||= CurriculumChoices.new

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

    holding = pages_holding_results
    @curriculum.assign_page_kinds(kinds)
    @withdrawn_pages = holding.reject { |number, kind| page_kind(number) == kind }.keys
    nil
  end

  # 読み取りの結果を持つページの { 番号 => 種別 }。読めたあとの読み直しが失敗したページも、前の結果は document に残っているので含める。
  def pages_holding_results
    @curriculum.pages.select { |page| page['contributed'].present? }.to_h { |page| [page['page'], page['kind']] }
  end

  def page_kind(number)
    @curriculum.pages.find { |page| page['page'] == number }['kind']
  end

  # 種別を替えたページは読み取りの結果を外して未読に戻す。気づかないまま消えないよう、どのページか知らせる。
  def saved_notice
    return 'ページの指定を保存しました。' if @withdrawn_pages.blank?

    "ページの指定を保存しました。種別を替えた#{@withdrawn_pages.join('・')}ページの読み取り結果は外しました" \
      '(確認済みの科目と、人が直した規則・章・行は残ります)。必要なら読み直してください。'
  end
end

