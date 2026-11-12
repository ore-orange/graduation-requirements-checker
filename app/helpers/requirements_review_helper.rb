# frozen_string_literal: true

# 要件表の確認画面(curricula/_requirements_*)の部品。値の書式と、フォームの欄の名前・種類をここに集める。
module RequirementsReviewHelper
  RULE_TYPE_NAMES = { 'credit_sum' => '区分の合計単位', 'all_required' => '必修をすべて修得', 'one_of_paths' => '指定科目の系列',
                      'grouped_max' => '同じ提供元・言語から', 'any_of' => 'どれか1つを満たす', 'all_of' => 'すべてを満たす',
                      'cap' => '算入の上限', 'exclude' => '算入しない' }.freeze
  FIELD_NAMES = CurriculumImport::RequirementsEdit::FIELD_LABELS
  # 入力欄の見た目。くわしくは app/assets/tailwind/application.css の .rv-field。
  # 行・決まりの数だけ繰り返すので、クラスの並びを直書きしない(1画面が重くなる)。
  FIELD_CLASS = 'rv-field'

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

  # 経路に置く役割を選ぶチェックの並び。選択肢は便覧が知っている役割。
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

  # 規則のフォームの欄の名前の前半(rules[添字])。どの枠で出しても、同じ名前で送る。
  # 添字は id で引く(同じ中身の規則が2つあっても、別の添字になる)。
  def rule_param_key(rule, review)
    "rules[#{review.rules.index { |candidate| candidate['id'] == rule['id'] }}]"
  end

  # ---- 「◯単位以上 〜 ◯単位以下」(設計書 項目3) ----

  # 決まりの箱で、場所を決めて出す欄。
  RULE_LOWER_FIELD = 'required_credits'
  RULE_UPPER_FIELD = 'credits'
  RULE_RANGE_FIELDS = [RULE_LOWER_FIELD, RULE_UPPER_FIELD].freeze
  # 対象の区分。判定が何を数えるかを決める値なので、常時出す。
  RULE_TARGET_FIELDS = %w[categories category required_categories].freeze
  # 対象の区分のほかに、判定が当たる範囲を決める欄。これも畳まない
  # (必修の科目数・グループの分け方・科目番号の接頭辞を読み違えると、判定が変わる)。
  # 算入しない科目の条件と理由も、畳まない(設計書 項目9)。当たる科目の単位は、修得していても消える。
  RULE_SHOWN_FIELDS = %w[expected_course_count group_by number_prefix number_prefix_mode numbers reason].freeze
  # 経路・選択肢・条件は、1つの欄ではなく繰り返しの行で出す。
  RULE_NESTED_KINDS = %i[paths options conditions].freeze

  # 決まりの箱に出す欄を、出す場所ごとに分ける(設計書 項目3・7)。
  #   lower・upper … 「◯以上〜◯以下」の2つの欄を、この決まりが持つか
  #   target … 対象の区分  shown … 判定が当たる範囲を決める欄  nested … 経路・選択肢・条件
  #   rest  … 残り(「…」の中。判定の数字を決めない値だけ)
  def rule_field_groups(rule)
    fields = CurriculumImport::RequirementsEdit.rule_fields(rule)
    nested, plain = fields.partition { |_, kind| RULE_NESTED_KINDS.include?(kind) }
    target, other = plain.partition { |field, _| RULE_TARGET_FIELDS.include?(field) }
    shown, rest = other.partition { |field, _| RULE_SHOWN_FIELDS.include?(field) }
    { nested: nested, target: target, shown: shown,
      rest: rest.to_h.except(*RULE_RANGE_FIELDS).to_a,
      lower: fields.key?(RULE_LOWER_FIELD), upper: fields.key?(RULE_UPPER_FIELD) }
  end

  # 「◯以上 〜 ◯以下」の2つの欄。章・枠・行・決まりで同じ形にする。
  # lower・upper は [欄の名前, 値] なら入力欄、それ以外(数・nil)は読むだけの枠。
  # 読むだけの枠には name を付けない。名前の無い欄はブラウザも送らないので、
  # 「触らずに保存したとき、文書が1バイトも変わらない」を壊さない。
  def credit_range(lower, upper, note: nil)
    parts = [credit_slot(lower, '下限なし(数えるだけ)'), tag.span('〜', class: 'text-slate-400'),
             credit_slot(upper, '上限なし'), tag.span('単位', class: 'font-medium text-slate-600')]
    parts << tag.span(note, class: 'text-amber-800') if note
    tag.span(safe_join(parts, ' '), class: 'inline-flex items-center gap-1 whitespace-nowrap text-xs')
  end

  def credit_slot(slot, title)
    if slot.is_a?(Array)
      return rv_number(slot.first, slot.last, id: nil,
                                              class: "w-16 text-right tabular-nums #{FIELD_CLASS}")
    end

    tag.span(review_credits(slot), title: slot.nil? ? title : nil, class: 'rv-slot')
  end

  # 必要単位(下限)も、その代わりに出す言葉も無い行。学生の画面では上の章の単位に含まれる。
  # 「内数」は画面にだけ出し、文書には書き込まない(設計書 項目3)。
  def inner_row?(row) = row['required_credits'].nil? && row['required_label'].blank?

  # 規則の1つの欄の入力。欄の種類は RequirementsEdit.rule_fields と同じ表から決まる。
  def rule_field_input(name, field, kind, rule, review)
    hint = rule['type'] == 'exclude' ? RequirementsExcludeHelper::FIELD_HINTS[field].to_s : ''
    label = tag.span("#{FIELD_NAMES.fetch(field, field)}#{hint}", class: 'text-xs font-semibold text-slate-700')
    tag.div(label + rule_field_control(name, field, kind, rule[field], review), class: 'space-y-1')
  end

  def rule_field_control(name, field, kind, value, review)
    return category_chips(name, value, review, label: nil) if kind == :set
    return rv_number(name, value, id: nil, class: "w-28 #{FIELD_CLASS}") if %i[number count].include?(kind)
    return category_select(name, value, review) if field == 'category'
    return prefix_select(name, value, review) if field == 'number_prefix'
    return prefix_mode_picks(name, value) if field == 'number_prefix_mode'
    return number_list_field(name, value, review) if kind == :optional_list

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

