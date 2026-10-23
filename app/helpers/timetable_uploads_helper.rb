# frozen_string_literal: true

module TimetableUploadsHelper
  GRADE_CHOICES = %w[1 2 3 4 1・2 2・3 3・4 1・2・3 2・3・4 1・2・3・4].freeze
  PERIOD_CHOICES = %w[1 2 3 4 5 6 1・2 2・3 3・4 4・5 5・6 1・2・3 2・3・4 3・4・5 4・5・6].freeze
  TERM_CHOICES = %w[半年 1Q 2Q 通年 集中].freeze

  # 決まった値から選ばせるプルダウン。PDFの値が選択肢に無いときも、値を失わないよう選択肢外として残す。
  def choice_options(choices, current)
    items = choices.map { |choice| [choice, choice] }
    items << ["#{current}（選択肢にありません）", current] if current.present? && choices.exclude?(current)
    options_for_select([['', '']] + items, current.to_s)
  end

  # 既存の講義と被っている行の選択肢。選ばれていない間だけ、「選んでください」を出す。
  def course_choice_options(row, candidates)
    items = candidates.map do |course|
      label = candidates.one? ? '既存の講義として扱う' : "既存の講義（ID #{course.id}）として扱う"
      [label, course.id.to_s]
    end
    items << %w[別の講義として登録 new]
    items.unshift(['選んでください', '']) unless row.course_choice_resolved?
    options_for_select(items, row.course_choice)
  end
end

