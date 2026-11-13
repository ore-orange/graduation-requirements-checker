# frozen_string_literal: true

# 経路(one_of_paths)の科目を選ぶチップ(設計書 項目3-1)。
#
# いままでの画面は、便覧じゅうの役割キーを英語のまま並べたチェックだった。
# 「日本語表現法入門を修得していること」を表すのに、関係のない微分積分学や物理学の役割まで混ざって出ていた。
#
# ここでは、選んである科目だけをチップで出し、足すのは「区分を選ぶ → その区分の科目を選ぶ」の2段。
# 2024年度は484科目あるので、1つの選択肢には並べない。
#
# 対象の区分のチップ(RequirementsChipsHelper)と同じ作りにしてある。チップの × はチェックを外すラベルで、
# JavaScript が無くても、保存すれば結果が見える。
module RequirementCourseChipsHelper
  def course_chips(name, path, review, rule)
    chosen = review.path_courses(path)
    tag.div(class: 'mt-1 flex flex-wrap items-center gap-1.5 text-sm', data: { controller: 'chip-adder' }) do
      safe_join([hidden_field_tag("#{name}[]", '', id: nil),
                 tag.span(safe_join(chosen.map { |key, label| course_chip(name, key, label) }, ' '),
                          class: 'flex flex-wrap gap-1.5', data: { chip_adder_target: 'chips' }),
                 (chosen.empty? ? tag.span('(科目が選ばれていません)', class: 'text-rose-700') : nil),
                 course_adder(name, chosen.map(&:first), review, rule)].compact)
    end
  end

  # チップは「いま選んである」ことそのもの。チェックは必ず入れる(外すのは × で、外したチップは描かれない)。
  def course_chip(name, key, label)
    tag.label(class: 'rv-chip') do
      check_box_tag("#{name}[]", key, true, id: nil, class: 'peer sr-only') +
        tag.span(safe_join([label, tag.span('×', class: 'font-bold', 'aria-hidden': true)], ' '),
                 class: 'rv-chip-text')
    end
  end

  # 足す科目を選ぶ2段の選択肢。区分を選ぶと、その区分の科目だけが出る(course_picker コントローラ)。
  # 区分の選択は送らない(名前を付けない)。送るのは、選んだ科目の key だけ。
  def course_adder(name, chosen, review, rule)
    options = review.path_category_options(rule)
    return if options.empty?

    tag.span(class: 'inline-flex flex-wrap items-center gap-1.5', data: { controller: 'course-picker' }) do
      course_category_select(options) + course_key_select(name, chosen, review, options)
    end
  end

  def course_category_select(options)
    tag.label do
      tag.span('科目の区分を選ぶ', class: 'sr-only') +
        select_tag(nil, options_for_select(options), include_blank: '＋ 科目を足す', id: nil, name: nil,
                                                     data: { course_picker_target: 'category',
                                                             action: 'change->course-picker#pick' },
                                                     class: 'rv-field py-0.5')
    end
  end

  # 科目の選択肢は、区分ごとに data-category を付けて全部描いておく。
  # こうすると JavaScript が無くても、一覧から選んで保存できる(絞り込みが効かないだけ)。
  def course_key_select(name, chosen, review, options)
    groups = options.map do |label, key|
      tag.optgroup(label: label, data: { category: key }) do
        safe_join(review.course_options(key, chosen).map { |text, value| tag.option(text, value: value) })
      end
    end
    tag.label do
      tag.span('足す科目を選ぶ', class: 'sr-only') +
        select_tag(adder_name(name), safe_join([tag.option('科目を選んでください', value: '')] + groups),
                   id: nil, data: { course_picker_target: 'course', chip_adder_target: 'select',
                                    action: 'change->chip-adder#add', name: "#{name}[]" },
                   class: 'rv-field py-0.5')
    end
  end
end

