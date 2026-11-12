# frozen_string_literal: true

# 要件表の確認画面の「対象の区分」(設計書 項目2)。
#
# 便覧の区分を23個のチェックとして毎行に並べるのをやめ、選んである区分だけをチップで出し、
# 足すのは選択肢1つからにする。並べると、行と決まりの数だけ繰り返して1画面が重くなるうえ、
# 「いまどの区分を数えているか」が、並んだチェックの中から読み取れない。
#
# チップの × は、そのチップのチェックを外すラベル。足す区分は別の欄(…[add][categories])で送る。
# どちらも JavaScript が無くても使えて、保存すれば結果が見える(chip-adder は、その場で見せるだけ)。
module RequirementsChipsHelper
  def category_chips(name, selected, review, label: '対象：')
    chosen = requirements_review.chosen_categories(name, selected) & review.category_keys
    tag.div(class: 'mt-1.5 flex flex-wrap items-center gap-1.5 text-xs', data: { controller: 'chip-adder' }) do
      safe_join([(label ? tag.span(label, class: 'font-semibold text-slate-700') : nil),
                 hidden_field_tag("#{name}[]", '', id: nil),
                 tag.span(safe_join(chosen.map { |key| category_chip(name, key, review) }, ' '),
                          class: 'flex flex-wrap gap-1.5', data: { chip_adder_target: 'chips' }),
                 (chosen.empty? ? tag.span('(なし)', class: 'text-rose-700') : nil),
                 category_adder(name, review.category_keys - chosen, review)].compact)
    end
  end

  # チップは「いま選んである」ことそのもの。チェックは必ず入れる(外すのは × で、外したチップは描かれない)。
  # rv_check は送信の中身で入り切りを決めるので使わない。足した区分は別の欄で送られ、
  # そこは chosen_categories が見ている(二重に見ると、足した区分のチップが外れたまま出てしまう)。
  def category_chip(name, key, review)
    tag.label(class: 'rv-chip') do
      check_box_tag("#{name}[]", key, true, id: nil, class: 'peer sr-only') +
        tag.span(safe_join([review.category_label(key), tag.span('×', class: 'font-bold', 'aria-hidden': true)], ' '),
                 class: 'rv-chip-text')
    end
  end

  # 足す区分を選ぶ1つの選択肢。欄の名前は、チップと同じ欄の「足す」側(…[add][categories])。
  # 別の名前で送るので、チップと同じ値を2か所から送ることにはならない。
  def category_adder(name, keys, review)
    return if keys.empty?

    options = keys.map { |key| [review.category_label(key), key] }
    data = { chip_adder_target: 'select', action: 'change->chip-adder#add', name: "#{name}[]" }
    tag.label do
      tag.span('対象の区分を足す', class: 'sr-only') +
        rv_select(adder_name(name), options, nil, include_blank: '＋ 区分を足す', id: nil, data: data,
                                                  class: 'rv-field py-0.5')
    end
  end

  # categories → add][categories。欄の名前の作り方を1か所に置く(保存側の読み方と揃える)。
  def adder_name(name)
    name.sub(/\[([^\[\]]+)\]\z/) { "[add][#{Regexp.last_match(1)}]" }
  end
end

