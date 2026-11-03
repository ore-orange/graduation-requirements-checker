# frozen_string_literal: true

# 便覧PDFを上げて下書き（Curriculum）を作り、どのページを読むかを人が決める画面。
# 一覧とアップロードの入口は /requirements にあり、ここは下書きの確認画面。
# アップロードと同じリクエストの中で、ページ画像とページごとの文字を取り出し、PDFは捨てる。
# 読み取り(AI)は1ページずつ、画面から1リクエストごとに同期で行う。公開の可否は CurriculumImport::Publication が1か所で決める。
class CurriculaController < ApplicationController
  include LocalAccessOnly
  include CurriculaCourses

  MAX_PDF_BYTES = 10.megabytes
  # 識別名(slug)は入力させない(Curriculum が学部名・学科コース名から決める)ので、ここに欄の名前は無い。
  FIELD_LABELS = { admission_year: '入学年度', faculty_name: '学部名', department_name: '学科・コース名' }.freeze
  # 学部名・学科コース名のプルダウンで「その他（新しく登録する）」を選んだ印。名前としては保存しない。
  # 空文字にしないのは、「何も選んでいない」と区別するため。選ぶと、横の自由入力欄(*_name_other)の値が名前になる。
  NEW_PROGRAM = '__other__'

  helper_method :requirements_review, :publication

  # update_courses・edit_course・bulk_confirm_courses は CurriculaCourses(concern)が定義する。
  before_action :load_draft, only: # rubocop:disable Rails/LexicallyScopedActionFilter
    %i[show update update_rules update_courses bulk_confirm_courses edit_course destroy page_image read_page publish]

  rescue_from ActiveRecord::RecordNotFound do
    redirect_to requirements_path, alert: 'この下書きは見つかりません。削除された可能性があります。', status: :see_other
  end

  def show
    @review = CurriculumImport::RequirementsReview.new(@curriculum)
  end

  # 下書きを公開する。可否は Publication が決め、止めるときは理由を画面に返す(何も変えない)。
  # 警告があれば、画面が見せた一覧の指紋(acknowledged)が要る。同じ識別名・入学年度の公開済みの差し替えは、replace を選んだときだけ。
  def publish
    @curriculum.publish!(acknowledged: params[:acknowledged], replace: params[:replace] == '1')
    redirect_to requirements_location, notice: '便覧を公開しました。学生の卒業判定に使われます。', status: :see_other
  rescue CurriculumImport::Publication::Refused => e
    redirect_to curriculum_path(@curriculum, anchor: 'publish'), status: :see_other,
                                                                 alert: "公開できませんでした(何も変えていません)。#{e.reasons.first}"
  end

  # 公開済みの便覧を直すための下書き。公開済みの行は書き換えず、document をコピーした下書きを新しく作る。
  def duplicate
    published = Curriculum.published.find(params.expect(:id))
    draft = CurriculumImport::Duplicate.call(published)
    redirect_to draft, notice: '公開済みの便覧を複製して、下書きを作りました。直したあとに公開すると、差し替えられます。', status: :see_other
  end

  # 区分ごとに、まだ確認していない科目をまとめて確認する。対象と指紋は CoursesReview が決める(courses_review と同じ1か所)。
  # 区分全体の行がまとめて変わるので、Turbo にはせず素直に画面を開き直す(「読み落とした科目を足す」と同じ考え方)。
  # ロックの中で公開済みに変わっていないかも確かめる(update_courses と同じ理由)。
  def bulk_confirm_courses
    result = nil
    published = false
    @curriculum.with_lock do
      published = @curriculum.published?
      unless published
        result = CurriculumImport::BulkConfirm.new(@curriculum, category: params[:category], rev: params[:rev]).call
      end
    end
    return redirect_to requirements_location, alert: published_alert, status: :see_other if published

    anchor = helpers.course_category_dom_id(params[:category])
    redirect_to curriculum_path(@curriculum, anchor: anchor), (result.ok? ? :notice : :alert) => result.message,
                                                              status: :see_other
  end

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
    # まだ便覧が無い(入力が不正で作れない)ので、選択は引き継がない。選択だけの最初の画面に戻して理由を出す。
    return redirect_to requirements_path, alert: error, status: :see_other if error

    curriculum.pages = []
    curriculum.save_upload!
    import_material(curriculum, file.path)
    redirect_to curriculum, notice: '下書きを作りました。読むページを選んでください。', status: :see_other
  end

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
    return redirect_to requirements_location, alert: published_alert, status: :see_other if notice == published_alert
    return redirect_to @curriculum, alert: notice, status: :see_other if notice.is_a?(String)

    redirect_to @curriculum, notice: saved_notice, status: :see_other
  end

  # 要件表の確認画面(規則・区分・章と行・総単位・注釈の扱い)で人が直した値を、下書きに入れる。
  # 直したものは、読み直しから守る印(confirmed)を付けて持つ。送られなかった項目は消さない(RequirementsEdit)。
  # 読み取り(ReadPage)も同じ行をロックして document を書くので、ここも行を取り直してロックし、最新の上で直す。
  # ロックの中で公開済みに変わっていないかも、もう一度確かめる(update と同じ理由)。
  def update_rules
    result = nil
    published = false
    @curriculum.with_lock do
      published = @curriculum.published?
      result = CurriculumImport::RequirementsEdit.new(@curriculum, rules_params).call unless published
    end
    return redirect_to requirements_location, alert: published_alert, status: :see_other if published
    return redirect_to rules_review_path, notice: edit_success_message(result), status: :see_other if result.ok?
    # 画面を開いたあとに中身が変わっていたら、いまの中身で開き直す(送られた入力は、古い中身の位置に結びついている)。
    return redirect_to rules_review_path, alert: result.errors.first, status: :see_other if result.stale

    render_rejected(result)
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

  # 要件表の確認画面が見せるもの(show と、保存できなかったときの開き直しが作る)。ビューの入力欄の部品が読む。
  def requirements_review = @review

  # 公開の欄が見せるもの。差し替えを選んだ前提で理由を並べる(差し替えの要・不要は、欄の中で別に聞く)。
  # 保存できなかった要件表の画面(render_rejected)も show を描くので、show では作らず、使うときに作る。
  def publication = @publication ||= CurriculumImport::Publication.new(@curriculum, replace: true)

  # 要件表の確認の入力。入れ子の形(章の中の行など)は、RequirementsEdit が1つずつ読んで型を確かめる。
  def rules_params
    params.to_unsafe_h.slice('revision', 'categories', 'rules', 'display', 'new_rule_json', 'new_group', 'new_row',
                             'annotations', 'remove_approval_note')
  end

  def rules_review_path = curriculum_path(@curriculum, anchor: 'requirements_review')

  # 保存できなかったときは、送られた入力を残したまま、要件表の画面を開き直す。問題は全部、項目の下と上に出す。
  # 何百という欄を直した人が、1つの打ち間違いで、すべてを打ち直さなくて済むように。
  def render_rejected(result)
    submission = CurriculumImport::RequirementsReview::Submission.new(submitted_pairs)
    @review = CurriculumImport::RequirementsReview.new(@curriculum, submission: submission, problems: result.problems,
                                                                    touched: result.touched)
    flash.now[:alert] = "要件表の修正を保存できませんでした(何も変えていません)。#{result.problems.size}件の問題を、下の要件表で直してください。"
    render :show, status: :unprocessable_content
  end

  # 送られた欄を、送られた名前のまま取り出す(入れ子のパラメータに直す前の形)。
  def submitted_pairs
    return [] unless request.form_data?

    URI.decode_www_form(request.raw_post)
  rescue ArgumentError
    []
  end

  def edit_success_message(result)
    shown = result.notes.first(3).join(' ')
    return shown if result.edited.zero?

    "要件表の修正を保存しました(#{result.edited}件)。直した項目は人が確認した値として残り、読み直しでは上書きしません。#{shown}"
  end

  def upload_params
    @upload_params ||= begin
      raw = params[:curriculum]
      # ?curriculum=x のように、ハッシュでない値が来ても落とさず、空の入力として扱う
      raw = ActionController::Parameters.new unless raw.is_a?(ActionController::Parameters)
      # slug は受けない。画面に欄が無く、課程を取り違える入力口になるので、送られても読まない。
      raw.permit(:admission_year, :faculty_name, :department_name, :faculty_name_other, :department_name_other, :file)
    end
  end

  # 下書きの属性。学部名・学科コース名は、プルダウンの選択か、「その他」を選んだときの自由入力のどちらか。
  # 「その他」を選んだ自由入力も、選択と同じ検証(必須・正規化)を通る。
  def curriculum_attributes
    { admission_year: upload_params[:admission_year],
      faculty_name: chosen_name(:faculty_name), department_name: chosen_name(:department_name) }
  end

  def chosen_name(field) = upload_params[field] == NEW_PROGRAM ? upload_params[:"#{field}_other"] : upload_params[field]

  # 操作した便覧の、卒業要件の確認画面。選択を引き継いで、操作の結果をそのまま見せる(選択なしの画面に戻すと、
  # 自分の操作のあとに空の画面へ落ちる)。学部名・学科コース名を持たない古い行は選択できないので、選択なしの画面にする。
  # 公開・削除のあとでも属性はメモリに残っているので、削除した行からも作れる。
  def requirements_location(curriculum = @curriculum)
    selection = { faculty: curriculum.faculty_name, department: curriculum.department_name,
                  admission_year: curriculum.admission_year }
    selection.values.all?(&:present?) ? requirements_path(selection) : requirements_path
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

  def upload_error(curriculum, file)
    unless curriculum.valid?(:upload)
      labels = curriculum.errors.attribute_names.filter_map { |name| FIELD_LABELS[name] }
      return "#{labels.join('・')}を正しく入力してください。"
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

