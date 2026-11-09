# frozen_string_literal: true

# 要件表の確認画面(curricula/_requirements_*)の部品。値の書式と、フォームの欄の名前・種類をここに集める。
module RequirementsReviewHelper
  RULE_TYPE_NAMES = { 'credit_sum' => '区分の合計単位', 'all_required' => '必修をすべて修得', 'one_of_paths' => '指定科目の系列',
                      'grouped_max' => '同じ提供元・言語から', 'any_of' => 'どれか1つを満たす', 'all_of' => 'すべてを満たす',
                      'cap' => '算入の上限', 'exclude' => '算入しない' }.freeze
  FIELD_NAMES = CurriculumImport::RequirementsEdit::FIELD_LABELS
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

  # 経路に置く役割を選ぶチェックの並び。区分のチェック(category_checks)と同じ形で、選択肢は便覧が知っている役割。
  # 役割のキーには、その役割を持つ科目の名前を添える(キーだけでは、どの科目を指すのか画面から分からない)。
  def role_checks(name, selected, review)
    boxes = review.known_roles.map do |role|
      names = review.role_names(role).first(2).join('・')
      tag.label(class: 'inline-flex items-center gap-1 whitespace-nowrap text-xs text-slate-800') do
        rv_check("#{name}[]", role, Array(selected).include?(role), id: nil) +
          "#{role}#{"(#{names})" if names.present?}"
      end
    end
    hidden_field_tag("#{name}[]", '', id: nil) + tag.div(safe_join(boxes), class: 'flex flex-wrap gap-x-3 gap-y-1')
  end

  # 規則のフォームの欄の名前の前半(rules[添字])。規則の一覧でも、ツリーの中の枠でも、同じ名前で送る。
  def rule_param_key(rule, review)
    "rules[#{review.rules.index(rule)}]"
  end

  # 入れ子を持つ規則のうち、この場所が枠を出すもの。同じ規則を2か所に出すと、同じ名前のパラメータが
  # 2回送られ、触っていない規則が「直した」ことになってしまう。だから、1ページにつき最初の1か所だけが出す。
  # 章・行(ツリー)が先に出て、どこからも指されていない規則だけが、あとの規則の一覧で出る。
  def nested_rule_boxes(ids, review)
    rules_for(ids, review).select { |rule| rule_logic_label(rule) && review.claim_rule_box?(rule['id']) }
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

  def human_confirmed?(item) = item[CurriculumImport::DraftMerge::CONFIRMED] == true

  def annotation_type_options
    CurriculumImport::Annotations::RULE_TYPES.map { |type| ["規則にする: #{rule_type_name(type)}(#{type})", type] }
  end
end

