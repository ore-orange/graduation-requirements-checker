# frozen_string_literal: true

# 科目表の確認画面(/curricula/:id の下半分)の操作。1科目ずつ確認・修正・削除・追加を保存する。
#
# 要件表の確認(update_rules)は、画面の全部を1つのフォームで送る。科目表は484行あり、欄は数千になる(Rack の
# パラメータ数の上限に近づき、1つの打ち間違いで全部が止まる)ので、こちらは1科目ずつ送る。
# だから、保存できなかったときに失うのは、その1科目の入力だけ。それは残して開き直す(失わない)。
# Turbo の画面では、保存した科目の行だけを差し替える(484行を作り直さず、スクロールの位置も残る)。
module CurriculaCourses
  extend ActiveSupport::Concern

  included do
    helper_method :courses_review
  end

  COURSE_PARAMS = (%w[key number rev confirmed _destroy added_by_hand] + CurriculumImport::CourseEdit::FIELDS.keys).uniq.freeze

  # 1科目の直す欄。科目の行の「直す」を押したときだけ取りに来る(行ごとに入れると、484行ぶんの欄と選択肢でページが膨らむ)。
  # Turbo では、その科目の行のあとへ欄だけを入れる(開いたままの欄は閉じて入れ直す。「やめる」は閉じるだけ)。
  def edit_course
    @course = Array(@curriculum.document['courses']).grep(Hash).find { |course| course['key'] == params[:key].to_s }
    return head :not_found unless @course

    respond_to do |format|
      format.turbo_stream { render turbo_stream: edit_course_streams }
      format.html
    end
  end

  # 科目1つの確認・修正・削除、または読み落とした科目の追加。document 全体は書き戻さない(CourseEdit)。
  # 行をロックして、読み取り(ReadPage)・要件表の保存と順に並べる。
  def update_courses
    result = nil
    @curriculum.with_lock { result = CurriculumImport::CourseEdit.new(@curriculum, courses_params).call }
    respond_to do |format|
      format.turbo_stream { turbo_course_response(result) }
      format.html { html_course_response(result) }
    end
  end

  private

  def courses_review
    # 突き合わせは画面を開くたびに走る重い処理。要件表の画面と同じ結果を共有する(編集欄だけを取りに来たときは、走らせない)。
    @review ||= CurriculumImport::RequirementsReview.new(@curriculum)
    @courses_review ||= CurriculumImport::CoursesReview.new(@review)
  end

  def edit_course_streams
    editor = helpers.course_edit_row_id(@course['key'])
    closed = turbo_stream.remove(editor)
    return closed if params[:cancel].present?

    locals = { review: courses_review, course: @course }
    row = helpers.course_dom_id(@course['key'])
    [closed, turbo_stream.append(row, partial: 'curricula/courses_edit_row', locals: locals)]
  end

  def courses_params = params.to_unsafe_h.slice(*COURSE_PARAMS)

  def adding_course? = CurriculumImport::CourseEdit::TRUE_VALUES.include?(params[:added_by_hand])

  def course_row_path(result) = curriculum_path(@curriculum, anchor: helpers.course_dom_id(result.key))

  # 保存できたら、その科目の行へ戻す(同じ画面を開き直しても、その場所から読める)。消した・足したあとは、足した行へ。
  def html_course_response(result)
    return render_courses_rejected(result) unless result.ok? || result.stale

    flash_key = result.ok? ? :notice : :alert
    message = result.ok? ? result.notes.first : result.errors.first
    target = result.ok? && result.key ? course_row_path(result) : curriculum_path(@curriculum)
    redirect_to target, flash_key => message, status: :see_other
  end

  # 保存できなかったときは、送られた入力を残したまま画面を開き直す。問題は、上と、その科目の行の下に出す。
  def render_courses_rejected(result)
    @review = CurriculumImport::RequirementsReview.new(@curriculum)
    @courses_review = rejected_review(result)
    flash.now[:alert] = '科目を保存できませんでした(何も変えていません)。入力は、その科目の「直す」に残してあります。'
    render :show, status: :unprocessable_content
  end

  def rejected_review(result)
    submission = CurriculumImport::RequirementsReview::Submission.new(submitted_pairs)
    editing = adding_course? ? :add : (result.key || params[:key])
    CurriculumImport::CoursesReview.new(@review, submission: submission, problems: result.problems, editing: editing)
  end

  # Turbo の画面。保存した科目の行・件数・問題の一覧だけを差し替える。足したときと、断られたとき(画面が古い)は、画面を開き直す。
  def turbo_course_response(result)
    return html_course_response(result) if adding_course? || result.stale
    return render_rejected_stream(result) unless result.ok?

    @review = CurriculumImport::RequirementsReview.new(@curriculum)
    render turbo_stream: course_streams(courses_review, result), status: :ok
  end

  def render_rejected_stream(result)
    @review = CurriculumImport::RequirementsReview.new(@curriculum)
    review = rejected_review(result)
    render turbo_stream: course_streams(review, result), status: :unprocessable_content
  end

  def course_streams(review, result)
    key = result.key || params[:key].to_s
    [course_row_stream(review, key), course_stream('courses_summary', review), course_stream('courses_errors', review),
     turbo_stream.update('courses_notice', result.ok? ? result.notes.first.to_s : '')]
  end

  def course_stream(target, review)
    turbo_stream.replace(target, partial: "curricula/#{target}", locals: { review: review })
  end

  # 消した科目は行ごと外す。それ以外は、いまの値で行を作り直す(確認済み・単位・区分・承認の表示が、保存した値になる)。
  def course_row_stream(review, key)
    row = review.rows.find { |entry| entry.key == key }
    target = helpers.course_dom_id(key)
    return turbo_stream.remove(target) unless row

    turbo_stream.replace(target, partial: 'curricula/courses_row', locals: { review: review, row: row })
  end
end

