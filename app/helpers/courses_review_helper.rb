# frozen_string_literal: true

# 科目表の確認画面(curricula/_courses_*)の部品。484行並ぶので、1行の HTML を小さく保つ(長い class は application.css の cr-*)。
module CoursesReviewHelper
  # 行の DOM の id。科目の key から作る(差し替え・移動の宛先)。key に空白などが入っていても、id として壊れないようにする。
  def course_dom_id(key)
    "course-#{key.to_s.gsub(/[^\p{L}\p{N}_-]/, '_')}"
  end

  # 「直す」で入る編集欄の行の id。
  def course_edit_row_id(key) = "course-edit-#{course_dom_id(key).delete_prefix('course-')}"

  # 行の色。公開を止める指摘 → 最初に見る科目 → 選べない科目 → 確認済み。
  def course_tone(row)
    return 'bg-rose-50' if row.reasons.include?(:blocking)
    return 'bg-amber-50' if row.look_first?
    return 'bg-rose-50/60' if row.course['selectable'] != true

    row.confirmed? ? 'bg-emerald-50/50' : ''
  end

  # 確認を外すボタンの確認文。人が直した値を持つ科目は、外すと読み直しで AI の読みに戻る(1回のクリックで、黙って起きない)。
  UNCONFIRM_WARNING = 'この科目には、人が直した値があります。確認を外すと、このページを読み直したとき、直した値は AI の読みに戻ります。外しますか?'

  def unconfirm_warning(course)
    UNCONFIRM_WARNING if course[CurriculumImport::CourseEdit::READ_FP].present?
  end

  def course_label(course)
    [course['number'], course['name']].compact_blank.join(' ').presence || course['key'].to_s
  end

  # 行の中の1操作(確認した・選べないにする など)。画面に1つだけある共有のフォーム(course_action_form)に、
  # 欄 form= で結びつけた送信ボタン。科目と値は formaction の問い合わせに持つ(科目ごとに484個のフォームを置かない)。
  # rev は、画面を開いたときのその科目の指紋。開いたあとに変わっていたら、保存は断られる。
  # 1行に何度も出るので、HTML は最小にする(読み上げは、押すと切り替わる状態を aria-pressed で言う)。
  def course_action(review, row, text, class_name: 'cr-btn', **params)
    pressed = params.delete(:pressed)
    confirm = params.delete(:confirm)
    path = update_courses_curriculum_path(review.curriculum, key: row.key, **params, rev: review.revision(row.course))
    tag.button(text, type: 'submit', form: 'course_action_form', formaction: path, class: class_name,
                     'aria-pressed': pressed, data: confirm && { turbo_confirm: confirm })
  end

  # 編集欄の入力。保存できなかった送信の入力があれば、それを残す(CoursesReview#field_value)。
  # 単位は文字の欄にする。数の欄(type=number)は、数でない文字をブラウザが捨てるので、打ち間違いが消えて、問題の文だけが残る。
  def cf_text(review, key, name, default, **)
    text_field_tag(name, review.field_value(key, name, default), id: nil, **)
  end

  def cf_number(review, key, name, default, **)
    text_field_tag(name, review.field_value(key, name, default), id: nil, inputmode: 'decimal', **)
  end

  def cf_check(review, key, name, default)
    hidden_field_tag(name, '0', id: nil) + check_box_tag(name, '1', review.field_checked?(key, name, default), id: nil)
  end

  def cf_select(review, key, name, default, **)
    options = options_for_select(review.category_options, review.field_value(key, name, default))
    select_tag(name, options, include_blank: '(選んでください)', id: nil, **)
  end
end

