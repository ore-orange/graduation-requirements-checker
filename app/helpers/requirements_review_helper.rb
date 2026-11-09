# frozen_string_literal: true

# 要件表の確認画面(curricula/_requirements_*)の部品。値の書式と、フォームの欄の名前・種類をここに集める。
module RequirementsReviewHelper
  RULE_TYPE_NAMES = { 'credit_sum' => '区分の合計単位', 'all_required' => '必修をすべて修得', 'one_of_paths' => '指定科目の系列',
                      'grouped_max' => '同じ提供元・言語から', 'any_of' => 'どれか1つを満たす', 'all_of' => 'すべてを満たす',
                      'cap' => '算入の上限', 'exclude' => '算入しない' }.freeze
  FIELD_NAMES = CurriculumImport::RequirementsEdit::FIELD_LABELS
  SUMMARY_FIELDS = %w[categories required_categories category required_credits expected_course_count group_by credits
                      number_prefix reason review_note].freeze
  FIELD_CLASS = 'rounded border border-slate-300 bg-white px-2 py-1.5 text-sm'

  # 単位の数。整数なら小数点を付けない。無ければダッシュ。
  def review_credits(value)
    return '—' unless value.is_a?(Numeric)

    value.to_d.then { |number| number.frac.zero? ? number.to_i.to_s : number.to_s('F') }
  end

  # 入れ子を持つ規則の論理。画面はこれをバッジにして、行の下の枠に出す。
  # 経路(one_of_paths)と選択肢(any_of)は「どれか1つ」、all_of は「すべて」。
  # それ以外(credit_sum など)は入れ子を持たないので、バッジも枠も作らない。
  RULE_LOGIC_LABELS = { 'one_of_paths' => 'OR', 'any_of' => 'OR', 'all_of' => 'AND' }.freeze

  def rule_type_name(type)
    RULE_TYPE_NAMES.fetch(type, type.presence || '(型なし)')
  end

  def rule_logic_label(rule) = RULE_LOGIC_LABELS[rule['type']]

  # 章・行が check_id/check_ids で指す規則そのもの。並びは指した順。見つからない id は含めない
  # (「規則が見つかりません」は、今までどおり requirements_rule_links が言う)。
  def rules_for(ids, review)
    Array.wrap(ids).filter_map { |id| review.rules.find { |rule| rule['id'] == id } }
  end

  # 規則の中身を、画面が一覧できる文の並びにする。判定の数字を決める値は、すべてここに出す
  # (上限・接頭辞・経路・入れ子の選択肢の必要単位)。読み違えると、数えてはいけない単位が数えられる値が、
  # 開かないと見えない JSON の中にあってはいけない。入れ子は、親の下に字下げして出す。
  def rule_summary(rule, review, depth = 0)
    indent = '　' * depth
    lines = [fields_line(rule, review)].compact.map { |line| "#{indent}#{line}" }
    lines.concat(path_lines(rule, review).map { |line| "#{indent}#{line}" })
    nested_rules(rule).each do |name, index, child|
      lines << "#{indent}#{name}#{index}: #{rule_type_name(child['type'])}"
      lines.concat(rule_summary(child, review, depth + 1))
    end
    lines
  end

  def fields_line(rule, review)
    parts = SUMMARY_FIELDS.filter_map do |field|
      "#{FIELD_NAMES.fetch(field)}: #{summary_value(rule[field], field, review)}" if rule.key?(field)
    end
    parts << '科目番号の接頭辞: なし(区分の全体)' if rule['type'] == 'exclude' && !rule.key?('number_prefix')
    parts.join(' / ').presence
  end

  # 経路は、役割のキーに、その役割を持つ科目の名前を添える。科目が1つも無い役割は、そう言う。
  def path_lines(rule, review)
    return [] unless rule['paths'].is_a?(Array)

    rule['paths'].each_with_index.map do |path, index|
      roles = Array(path).map { |role| "#{role}(#{review.role_names(role).first(3).join('・').presence || '科目なし'})" }
      "経路#{index + 1}: #{roles.join(' ＋ ').presence || '(空)'}"
    end
  end

  def nested_rules(rule)
    { 'options' => '選択肢', 'conditions' => '条件' }.flat_map do |field, name|
      Array(rule[field]).grep(Hash).each_with_index.map { |child, index| [name, index + 1, child] }
    end
  end

  def summary_value(value, field, review)
    return review_credits(value) if value.is_a?(Numeric)
    return '(空)' if value.nil?

    names = Array(value).map { |key| category_field?(field) ? review.category_label(key) : key.to_s }
    names.join('・').presence || '(空)'
  end

  def category_field?(field) = %w[categories required_categories category].include?(field)

  # 入力欄。保存できなかった送信の入力があれば、それを残して出す(RequirementsReview#field_value)。
  # 数は文字の欄にする。数の欄(type=number)は、数でない文字をブラウザが捨てるので、打ち間違いが消えて、問題の文だけが残ってしまう。
  def rv_text(name, default, **)
    text_field_tag(name, requirements_review.field_value(name, default), **)
  end

  def rv_number(name, default, **)
    text_field_tag(name, requirements_review.field_value(name, default), inputmode: 'decimal', **)
  end

  def rv_check(name, value, default, **)
    check_box_tag(name, value, requirements_review.field_checked?(name, value, default), **)
  end

  def rv_area(name, default, **)
    text_area_tag(name, requirements_review.field_value(name, default), **)
  end

  def rv_select(name, options, default, **)
    select_tag(name, options_for_select(options, requirements_review.field_value(name, default)), **)
  end

  # 区分を選ぶチェックの並び。1つも選ばないときも「空にする」と伝わるよう、先に空の値を送る。
  def category_checks(name, selected, review)
    boxes = review.category_keys.map do |key|
      tag.label(class: 'inline-flex items-center gap-1 whitespace-nowrap text-xs text-slate-800') do
        rv_check("#{name}[]", key, Array(selected).include?(key), id: nil) + review.category_label(key)
      end
    end
    hidden_field_tag("#{name}[]", '', id: nil) + tag.div(safe_join(boxes), class: 'flex flex-wrap gap-x-3 gap-y-1')
  end

  # 規則の1つの欄の入力。欄の種類は RequirementsEdit.rule_fields と同じ表から決まる。
  def rule_field_input(name, field, kind, rule, review)
    hint = field == 'number_prefix' ? '(空なら区分の全体)' : ''
    label = tag.span("#{FIELD_NAMES.fetch(field, field)}#{hint}", class: 'text-xs font-semibold text-slate-700')
    tag.div(label + rule_field_control(name, field, kind, rule[field], review), class: 'space-y-1')
  end

  def rule_field_control(name, field, kind, value, review)
    return category_checks(name, value, review) if kind == :set
    return rv_number(name, value, id: nil, class: "w-28 #{FIELD_CLASS}") if %i[number count].include?(kind)
    return category_select(name, value, review) if field == 'category'

    rv_text(name, value, id: nil, class: "w-full #{FIELD_CLASS}")
  end

  def category_select(name, selected, review)
    options = review.category_keys.map { |key| [review.category_label(key), key] }
    rv_select(name, options, selected, include_blank: true, id: nil, class: FIELD_CLASS)
  end

  # JSON の欄に出す規則。confirmed は人が直した印で、直す対象ではないので出さない。
  def rule_json(rule)
    JSON.pretty_generate(rule.except(CurriculumImport::DraftMerge::CONFIRMED))
  end

  def human_confirmed?(item) = item[CurriculumImport::DraftMerge::CONFIRMED] == true

  def annotation_type_options
    CurriculumImport::Annotations::RULE_TYPES.map { |type| ["規則にする: #{rule_type_name(type)}(#{type})", type] }
  end
end

